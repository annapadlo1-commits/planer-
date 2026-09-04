begin;
set transaction isolation level repeatable read, read only;
set local search_path='';
with
app_ns as (select oid,nspname from pg_catalog.pg_namespace where nspname in ('public','authorization_private','solver_private')),
app_rel as (select c.*,n.nspname from pg_catalog.pg_class c join app_ns n on n.oid=c.relnamespace),
ledger as (
 select version::text,coalesce(name,'')::text as name,coalesce(cardinality(statements),0) as statement_count,
 octet_length(coalesce(array_to_string(statements,E'\n'),'')) as sql_bytes,
 md5(coalesce(array_to_string(statements,E'\n'),'')) as sql_md5,
 encode(sha256(convert_to(coalesce(array_to_string(statements,E'\n'),''),'UTF8')),'hex') as sql_sha256,
 encode(sha256(convert_to(replace(coalesce(array_to_string(statements,E'\n'),''),E'\r\n',E'\n'),'UTF8')),'hex') as canonical_sql_sha256
 from supabase_migrations.schema_migrations
)
select jsonb_build_object(
 'format','aud003-uat-catalog-v2',
 'capturedAtUtc',clock_timestamp() at time zone 'UTC',
 'projectRef',(select config->>'projectRef' from public.uat_environment_controls where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'),
 'environment',(select config->>'environment' from public.uat_environment_controls where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'),
 'identityEnabled',(select enabled from public.uat_environment_controls where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'),
 'transactionReadOnly',current_setting('transaction_read_only'),
 'serverVersion',current_setting('server_version'),
 'sourceUatSha','16d93bc5ddfd0de7ac3ab566076471f1718e4f85',
 'trialMergeSha','92bc2c8bcbba780d251f5a37a7e56767ecdb6386',
 'ledger',jsonb_build_object(
   'count',(select count(*) from ledger),
   'sha256',(select encode(sha256(convert_to(string_agg(version||'|'||name||'|'||statement_count::text||'|'||sql_bytes::text||'|'||sql_sha256,E'\n' order by version),'UTF8')),'hex') from ledger),
   'rows',(select jsonb_agg(to_jsonb(l) order by version) from ledger l)),
 'schemas',(select jsonb_agg(to_jsonb(x) order by name) from (
   select n.nspname as name,pg_get_userbyid(n.nspowner) as owner,n.nspacl is null as acl_is_null,
     array(select a::text from unnest(coalesce(n.nspacl,acldefault('n',n.nspowner))) a order by a::text collate "C") as acl
   from pg_catalog.pg_namespace n where left(n.nspname,3)<>'pg_' and n.nspname<>'information_schema') x),
 'relations',(select jsonb_agg(to_jsonb(x) order by schema,name) from (
   select nspname as schema,relname as name,relkind::text as kind,relpersistence::text as persistence,
    pg_get_userbyid(relowner) as owner,relacl is null as acl_is_null,relrowsecurity as rls,relforcerowsecurity as force_rls,
    relreplident::text as replica_identity,relispartition as is_partition,pg_get_expr(relpartbound,oid) as partition_bound,
    case when relkind='p' then pg_get_partkeydef(oid) else null end as partition_key,
    coalesce(reloptions,array[]::text[]) as options,
    array(select a::text from unnest(coalesce(relacl,acldefault(case when relkind='S' then 's'::"char" else 'r'::"char" end,relowner))) a order by a::text collate "C") as acl
   from app_rel where relkind in ('r','p','v','m','S','f')) x),
 'columns',(select jsonb_agg(to_jsonb(x) order by schema,relation,ordinal) from (
   select r.nspname as schema,r.relname as relation,a.attname as name,a.attnum as ordinal,
    format_type(a.atttypid,a.atttypmod) as type,a.attnotnull as not_null,a.attidentity::text as identity,
    a.attgenerated::text as generated,pg_get_expr(d.adbin,d.adrelid) as default_expression,
    case when a.attcollation=0 then null else format('%I.%I',cn.nspname,co.collname) end as collation,
    array(select v::text from unnest(coalesce(a.attacl,array[]::aclitem[])) v order by v::text collate "C") as acl
   from app_rel r join pg_catalog.pg_attribute a on a.attrelid=r.oid and a.attnum>0 and not a.attisdropped
   left join pg_catalog.pg_attrdef d on d.adrelid=r.oid and d.adnum=a.attnum
   left join pg_catalog.pg_collation co on co.oid=a.attcollation left join pg_catalog.pg_namespace cn on cn.oid=co.collnamespace
   where r.relkind in ('r','p','v','m','f')) x),
 'constraints',(select jsonb_agg(to_jsonb(x) order by schema,relation,name) from (
   select n.nspname as schema,coalesce(r.relname,'') as relation,c.conname as name,c.contype::text as type,
    c.condeferrable as deferrable,c.condeferred as initially_deferred,c.convalidated as validated,
    pg_get_constraintdef(c.oid,true) as definition
   from pg_catalog.pg_constraint c join app_ns n on n.oid=c.connamespace
   left join pg_catalog.pg_class r on r.oid=c.conrelid) x),
 'indexes',(select jsonb_agg(to_jsonb(x) order by schema,relation,name) from (
   select r.nspname as schema,r.relname as relation,ic.relname as name,pg_get_indexdef(i.indexrelid) as definition,
    i.indisvalid as valid,i.indisready as ready,i.indisunique as unique,i.indisprimary as primary,i.indisreplident as replica_identity,
    (select c.conname from pg_catalog.pg_constraint c where c.conindid=i.indexrelid and c.contype in ('p','u','x') limit 1) as constraint_name
   from pg_catalog.pg_index i join app_rel r on r.oid=i.indrelid join pg_catalog.pg_class ic on ic.oid=i.indexrelid) x),
 'sequences',(select jsonb_agg(to_jsonb(x) order by schema,name) from (
   select r.nspname as schema,r.relname as name,format_type(s.seqtypid,null) as type,s.seqstart::text as start,s.seqincrement::text as increment,
    s.seqmax::text as max,s.seqmin::text as min,s.seqcache::text as cache,s.seqcycle as cycle
   from pg_catalog.pg_sequence s join app_rel r on r.oid=s.seqrelid) x),
 'sequenceOwnership',(select jsonb_agg(to_jsonb(x) order by schema,sequence) from (
   select n.nspname as schema,s.relname as sequence,tn.nspname as table_schema,t.relname as table_name,a.attname as column_name,d.deptype::text as dependency_type
   from pg_catalog.pg_class s join app_ns n on n.oid=s.relnamespace
   join pg_catalog.pg_depend d on d.classid='pg_catalog.pg_class'::regclass and d.objid=s.oid and d.deptype in ('a','i')
   join pg_catalog.pg_class t on t.oid=d.refobjid join pg_catalog.pg_namespace tn on tn.oid=t.relnamespace
   join pg_catalog.pg_attribute a on a.attrelid=t.oid and a.attnum=d.refobjsubid where s.relkind='S') x),
 'types',(select jsonb_agg(to_jsonb(x) order by schema,name) from (
   select n.nspname as schema,t.typname as name,t.typtype::text as kind,pg_get_userbyid(t.typowner) as owner,t.typacl is null as acl_is_null,
    t.typnotnull as not_null,t.typdefault as default_expression,
    case when t.typbasetype=0 then null else format_type(t.typbasetype,t.typtypmod) end as base_type,
    array(select e.enumlabel from pg_catalog.pg_enum e where e.enumtypid=t.oid order by e.enumsortorder) as enum_labels,
    array(select a::text from unnest(coalesce(t.typacl,acldefault('T',t.typowner))) a order by a::text collate "C") as acl
   from pg_catalog.pg_type t join app_ns n on n.oid=t.typnamespace left join pg_catalog.pg_class c on c.oid=t.typrelid
   where t.typtype in ('e','d','r','m') or (t.typtype='c' and c.relkind='c')) x),
 'routines',(select jsonb_agg(to_jsonb(x) order by schema,name,identity_arguments) from (
   select n.nspname as schema,p.proname as name,pg_get_function_identity_arguments(p.oid) as identity_arguments,
    pg_get_function_arguments(p.oid) as arguments,pg_get_function_result(p.oid) as result,p.prokind::text as kind,
    l.lanname as language,pg_get_userbyid(p.proowner) as owner,p.proacl is null as acl_is_null,p.prosecdef as security_definer,p.provolatile::text as volatility,
    p.proisstrict as strict,p.proleakproof as leakproof,p.proparallel::text as parallel,
    coalesce(p.proconfig,array[]::text[]) as config,
    array(select a::text from unnest(coalesce(p.proacl,acldefault('f',p.proowner))) a order by a::text collate "C") as acl,
    pg_get_functiondef(p.oid) as definition
   from pg_catalog.pg_proc p join app_ns n on n.oid=p.pronamespace join pg_catalog.pg_language l on l.oid=p.prolang
   where p.prokind in ('f','p')) x),
 'views',(select jsonb_agg(to_jsonb(x) order by schema,name) from (
   select nspname as schema,relname as name,relkind::text as kind,pg_get_viewdef(oid,true) as definition from app_rel where relkind in ('v','m')) x),
 'triggers',(select jsonb_agg(to_jsonb(x) order by schema,relation,name) from (
   select r.nspname as schema,r.relname as relation,t.tgname as name,t.tgenabled::text as enabled,pg_get_triggerdef(t.oid,true) as definition
   from pg_catalog.pg_trigger t join app_rel r on r.oid=t.tgrelid where not t.tgisinternal) x),
 'policies',(select jsonb_agg(to_jsonb(x) order by schemaname,tablename,policyname) from (
   select * from pg_catalog.pg_policies where schemaname in ('public','authorization_private','solver_private','auth','storage','realtime')) x),
 'defaultAcls',(select jsonb_agg(to_jsonb(x) order by schema,role,object_type) from (
   select coalesce(n.nspname,'') as schema,pg_get_userbyid(d.defaclrole) as role,d.defaclobjtype::text as object_type,
    array(select a::text from unnest(d.defaclacl) a order by a::text collate "C") as acl
   from pg_catalog.pg_default_acl d left join pg_catalog.pg_namespace n on n.oid=d.defaclnamespace) x),
 'extensions',(select jsonb_agg(to_jsonb(x) order by name) from (
   select e.extname as name,e.extversion as version,n.nspname as schema,pg_get_userbyid(e.extowner) as owner,e.extrelocatable as relocatable
   from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid=e.extnamespace) x),
 'publications',(select jsonb_agg(to_jsonb(x) order by name) from (
   select p.pubname as name,pg_get_userbyid(p.pubowner) as owner,p.puballtables as all_tables,p.pubinsert as insert,p.pubupdate as update,
    p.pubdelete as delete,p.pubtruncate as truncate,p.pubviaroot as via_root,
    (select jsonb_agg(to_jsonb(t) order by schemaname,tablename) from pg_catalog.pg_publication_tables t where t.pubname=p.pubname) as tables
   from pg_catalog.pg_publication p) x),
 'eventTriggers',(select jsonb_agg(to_jsonb(x) order by name) from (
   select t.evtname as name,t.evtevent as event,pg_get_userbyid(t.evtowner) as owner,t.evtenabled::text as enabled,t.evttags as tags,
    format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)) as function
   from pg_catalog.pg_event_trigger t join pg_catalog.pg_proc p on p.oid=t.evtfoid join pg_catalog.pg_namespace n on n.oid=p.pronamespace) x),
 'storageObjectsTable',(select jsonb_build_object('rls',relrowsecurity,'force_rls',relforcerowsecurity,'owner',pg_get_userbyid(relowner),'acl',relacl::text) from pg_catalog.pg_class where oid='storage.objects'::regclass),
 'storageBuckets',(select jsonb_agg(to_jsonb(x) order by id) from (
   select id,name,public,file_size_limit,allowed_mime_types,avif_autodetection,type::text,versioning_status::text from storage.buckets) x),
 'cronMetadata',(select jsonb_agg(to_jsonb(x) order by jobid) from (
   select jobid,schedule,active,jobname,encode(sha256(convert_to(command,'UTF8')),'hex') as command_sha256 from cron.job) x),
 'pgmqQueues',(select jsonb_agg(to_jsonb(x) order by queue_name) from (
   select queue_name,is_partitioned,is_unlogged from pgmq.meta) x)
) as capture;
rollback;
