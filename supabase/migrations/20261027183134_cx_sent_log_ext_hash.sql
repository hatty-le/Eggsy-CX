do $d$ declare src text; begin
 select pg_get_functiondef('public.cx_log_sent_reply(public.cx_origin,text,text,timestamptz,uuid,text,text,text,text,text,text,text,text,text)'::regprocedure) into src;
 src := replace(src, $q$'YYYY-MM-DD"T"HH24:MI:SS"Z"'));$q$, $q$'YYYY-MM-DD"T"HH24:MI:SS"Z"') || ':' || left(md5(p_body), 8));$q$);
 if src not like '%md5(p_body)%' then raise exception 'patch failed'; end if;
 execute src;
end $d$;
revoke execute on function public.cx_log_sent_reply(public.cx_origin,text,text,timestamptz,uuid,text,text,text,text,text,text,text,text,text) from public, anon, authenticated;