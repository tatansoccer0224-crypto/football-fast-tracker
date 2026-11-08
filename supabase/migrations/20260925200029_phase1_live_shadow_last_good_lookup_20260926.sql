create index if not exists live_expected_actual_history_last_good_idx
 on public.live_expected_actual_history (hkjc_event_id, captured_at_hkt desc)
 where live_metric_count > 0;
