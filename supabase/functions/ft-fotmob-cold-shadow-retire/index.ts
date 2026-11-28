import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "npm:@supabase/supabase-js@2.116.0";

// Strictly bounded cold archive of UNMATCHED, >7-day-old FotMob source
// events. Read entire source rows, archive without overwrite, SHA-256
// download/readback verify, then guarded exact-row transaction.
// Do not operate on current/linked/verified/canonically redirected fixtures.
const BUCKET="fast-tracker-ingest";
const MAX_ROWS=40,MAX_ARCHIVE_BYTES=2_600_000;
const response=(v:any,status=200)=>Response.json(v,{status,headers:{"Cache-Control":"private, no-store"}});
function key(){
 const direct=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(direct)return direct;
 try{return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")||"{}").default||"";}
 catch{return "";}
}
async function sha256(bytes:Uint8Array):Promise<string>{
 const digest=await crypto.subtle.digest("SHA-256",bytes);
 return [...new Uint8Array(digest)].map(v=>v.toString(16).padStart(2,"0")).join("");
}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return response({ok:false,error:"POST_ONLY"},405);
 if(new URL(req.url).search)return response({ok:false,error:"UNSUPPORTED_QUERY"},400);
 const cronKey=req.headers.get("x-ft-cron-key")||"";
 const url=Deno.env.get("SUPABASE_URL")||"",serviceKey=key();
 if(!url||!serviceKey)return response({ok:false,error:"SERVICE_CONFIG_UNAVAILABLE"},503);
 if(!cronKey)return response({ok:false,error:"UNAUTHORIZED"},401);
 let body:any;
 try{body=await req.json();}catch{return response({ok:false,error:"JSON_REQUIRED"},400);}
 if(!body||typeof body!=="object"||Array.isArray(body)||Object.keys(body).length)
   return response({ok:false,error:"EMPTY_JSON_ONLY"},400);
 const db=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const auth=await db.rpc("ft_internal_cron_key_matches",{p_key:cronKey});
 if(auth.error||auth.data!==true)return response({ok:false,error:"UNAUTHORIZED"},401);
 const result=await db.rpc("ft_fotmob_cold_unmatched_candidates",{p_limit:MAX_ROWS});
 if(result.error||!Array.isArray(result.data))
   return response({ok:false,error:"RETENTION_CANDIDATES_UNAVAILABLE"},503);
 let rows=result.data;
 if(!rows.length)return response({ok:true,status:"NO_COLD_UNMATCHED_RECORDS",archived:0,deleted:0});
 if(rows.length>MAX_ROWS)return response({ok:false,error:"CANDIDATES_OVER_LIMIT"},422);
 const ids=new Set<string>();
 const maxTime=Date.now()-7*86400000,updatedCutoff=Date.now()-6*86400000;
 for(const r of rows){
   if(r?.source_key!=="FOTMOB"||r.identity_status!=="UNMATCHED"||
     r.match_id!==null ||typeof r.external_event_id!=="string" ||
     !/^[0-9]{5,16}$/.test(r.external_event_id) ||
     ids.has(r.external_event_id) ||
     !Number.isFinite(Date.parse(r.fetched_at)) ||
     !Number.isFinite(Date.parse(r.kickoff_utc)) ||
     !Number.isFinite(Date.parse(r.updated_at)) ||
     Date.parse(r.fetched_at)>=maxTime||
     Date.parse(r.kickoff_utc)>=maxTime||
     Date.parse(r.updated_at)>=updatedCutoff
   )return response({ok:false,error:"CANDIDATE_IDENTITY_OR_AGE_INVALID"},422);
   ids.add(r.external_event_id);
 }
 // Keep strict original RPC candidate validation, then archive the largest
 // ordered prefix that fits the configured byte ceiling. A large first
 // record must fail closed; never truncate JSON or delete an unarchived row.
 const encoder=new TextEncoder();
 const HEADER_RESERVE_BYTES=4096;
 let selected=0, selectedBytes=0;
 for(const candidate of rows){
   const rowBytes=encoder.encode(JSON.stringify(candidate)+"\n").byteLength;
   if(rowBytes+HEADER_RESERVE_BYTES>MAX_ARCHIVE_BYTES){
     if(selected===0)return response({ok:false,error:"SINGLE_ROW_EXCEEDS_ARCHIVE_CAP"},413);
     break;
   }
   if(selectedBytes+rowBytes+HEADER_RESERVE_BYTES>MAX_ARCHIVE_BYTES)break;
   selectedBytes+=rowBytes;selected++;
 }
 rows=rows.slice(0,selected);
 const first=rows[0].external_event_id,last=rows.at(-1).external_event_id;
 const manifest={
   schema:"FT_UNMATCHED_FOTMOB_SHADOW_ARCHIVE_V1",
   source:"public.phase15_source_shadow_current",
   category:"FOTMOB_UNMATCHED_COLD_ONLY",
   daysAfterKickoff:7,recordCount:rows.length,
   eventIdFirst:first,eventIdLast:last,
   archiveMode:"SHA256_READBACK_BEFORE_EXACT_ROW_DELETE"
 };
 const raw=[JSON.stringify({manifest}),...rows.map((r:any)=>JSON.stringify(r))].join("\n")+"\n";
 const bytes=new TextEncoder().encode(raw);
 if(bytes.byteLength<100||bytes.byteLength>MAX_ARCHIVE_BYTES)
   return response({ok:false,error:"ARCHIVE_SIZE_OUT_OF_BOUNDS",size:bytes.byteLength},413);
 const sha=await sha256(bytes);
 const today=new Date().toISOString().slice(0,10);
 const path="shadow-cold/v1/FOTMOB/"+today+"/"+sha+".jsonl.txt";
 const storage=db.storage.from(BUCKET);
 const upload=await storage.upload(path,bytes,{contentType:"text/plain",upsert:false,cacheControl:"0"});
 if(upload.error&&!/already exists|duplicate|409/i.test(upload.error.message))
   return response({ok:false,error:"ARCHIVE_WRITE_FAILED"},503);
 const download=await storage.download(path);
 if(download.error||!download.data)
   return response({ok:false,error:"ARCHIVE_READBACK_FAILED"},503);
 const roundtrip=new Uint8Array(await download.data.arrayBuffer());
 if(roundtrip.length!==bytes.length||await sha256(roundtrip)!==sha)
   return response({ok:false,error:"ARCHIVE_CHECKSUM_FAILED"},409);
 const recovered=new TextDecoder().decode(roundtrip).trimEnd().split("\n");
 let verifiedManifest:any;
 try{verifiedManifest=JSON.parse(recovered[0])?.manifest;}catch{
   return response({ok:false,error:"ARCHIVE_MANIFEST_MISSING"},409);
 }
 if(verifiedManifest?.schema!==manifest.schema ||
    verifiedManifest?.recordCount!==rows.length ||
    verifiedManifest?.eventIdFirst!==first ||
    verifiedManifest?.eventIdLast!==last ||
    recovered.length!==rows.length+1)
   return response({ok:false,error:"ARCHIVE_MANIFEST_MISMATCH"},409);
 const exact=rows.map((r:any)=>({
   source_key:r.source_key,external_event_id:r.external_event_id,
   fetched_at:r.fetched_at,kickoff_utc:r.kickoff_utc,
   updated_at:r.updated_at,match_id:r.match_id,
   identity_status:r.identity_status,raw:r.raw,detail_raw:r.detail_raw
 }));
 const retired=await db.rpc("ft_retire_verified_fotmob_cold_batch",{
   p_rows:exact,p_storage_path:path,p_archive_sha:sha,
   p_archive_bytes:bytes.length
 });
 if(retired.error||retired.data!==rows.length)
   return response({ok:false,error:"EXACT_RETIRE_REJECTED",
     archived:true,deletionPerformed:false,archivePath:path,
     archivedRows:rows.length,deletedRows:0},503);
 await db.from("source_health").upsert({
   source:"FOTMOB_COLD_SHADOW",metric:"archive_verified_retire",
   value_text:String(rows.length),status:"OK",
   notes:"Original unmatched FotMob source rows including detail evidence archived in full, SHA256 readback verified, then deleted with protected-record guards.",
   observed_at:new Date().toISOString(),
   raw:{retired:rows.length,archive_path:path,sha256:sha,
     archive_bytes:bytes.length,retention_days:7,
     cutoff:"KICKOFF_AND_CAPTURE",mode:"UNMATCHED_ONLY"}
 },{onConflict:"source,metric"});
 return response({ok:true,status:"COLD_SHADOW_ARCHIVED_VERIFIED_AND_RETIRED",
   archived:rows.length,deleted:retired.data,
   source:"FOTMOB_UNMATCHED",archiveBytes:bytes.length,
   archivePath:path,sha256:sha,deletionPerformed:true,
   caveat:"Physical database allocation can remain unchanged until PostgreSQL maintenance"});
});
