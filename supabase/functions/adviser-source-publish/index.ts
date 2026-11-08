import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.1.0";
const keys=createRemoteJWKSet(new URL("https://token.actions.githubusercontent.com/.well-known/jwks"));
Deno.serve(async(req:Request)=>{
 const reply=(status:number,body:unknown)=>Response.json(body,{status,headers:{"Cache-Control":"no-store"}});
 if(req.method!=="POST")return reply(405,{error:"METHOD_NOT_ALLOWED"});
 let claims:any;
 try { const token=(req.headers.get("authorization")||"").match(/^Bearer (.+)$/i)?.[1];
  if(!token)return reply(401,{error:"OIDC_REQUIRED"});
  claims=(await jwtVerify(token,keys,{issuer:"https://token.actions.githubusercontent.com",audience:"fast-tracker-supabase"})).payload;
 } catch {return reply(401,{error:"INVALID_OIDC"});}
 if(claims.repository!=="tatansoccer0224-crypto/football-fast-tracker" || claims.ref!=="refs/heads/main"
   ||claims.workflow_ref!=="tatansoccer0224-crypto/football-fast-tracker/.github/workflows/adviser-source-capture.yml@refs/heads/main"
   ||!["schedule","workflow_dispatch","push"].includes(claims.event_name)||!/^\d{6,20}$/.test(String(claims.run_id)))
  return reply(403,{error:"UNAUTHORIZED_WORKFLOW"});
 let body:any;
 try {const text=await req.text();if(text.length>600000)return reply(413,{error:"BATCH_TOO_LARGE"});body=JSON.parse(text);}
 catch{return reply(400,{error:"INVALID_JSON"});}
 if(body?.contract!=="source_observations_only_v1"||!Array.isArray(body.records)||body.records.length>240)
  return reply(422,{error:"INVALID_ENVELOPE"});
 const base=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!base||!key)return reply(503,{error:"CONFIGURATION_UNAVAILABLE"});
 try {const r=await fetch(base+"/rest/v1/rpc/ft_ingest_adviser_observations",{method:"POST",
  headers:{apikey:key,authorization:"Bearer "+key,"content-type":"application/json"},
  body:JSON.stringify({p_rows:body.records,p_run_id:String(claims.run_id)}),signal:AbortSignal.timeout(15000)});
  if(!r.ok)return reply(503,{error:"INGEST_REJECTED"});return reply(200,await r.json());
 }catch{return reply(503,{error:"INGEST_UNAVAILABLE"});}
});
