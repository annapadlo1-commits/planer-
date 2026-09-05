\set ON_ERROR_STOP on
begin;

create temporary table aud014_compound_benchmark (
  matrix_version_id uuid not null,
  relation_id uuid,
  payload text not null
) on commit drop;

insert into aud014_compound_benchmark (matrix_version_id, relation_id, payload)
select
  ('00000000-0000-0000-0000-' || lpad((value % 100)::text, 12, '0'))::uuid,
  ('10000000-0000-0000-0000-' || lpad((value % 1000)::text, 12, '0'))::uuid,
  repeat('x', 32)
from generate_series(1, 200000) as series(value);

analyze aud014_compound_benchmark;
\echo AUD014_COMPOUND_BEFORE
explain (analyze, buffers, format json)
select count(*)
from aud014_compound_benchmark
where matrix_version_id = '00000000-0000-0000-0000-000000000042'
  and relation_id = '10000000-0000-0000-0000-000000000042';

create index aud014_compound_benchmark_idx
  on aud014_compound_benchmark (matrix_version_id, relation_id);
analyze aud014_compound_benchmark;
\echo AUD014_COMPOUND_AFTER
explain (analyze, buffers, format json)
select count(*)
from aud014_compound_benchmark
where matrix_version_id = '00000000-0000-0000-0000-000000000042'
  and relation_id = '10000000-0000-0000-0000-000000000042';

create temporary table aud014_single_benchmark (
  employee_id uuid not null,
  payload text not null
) on commit drop;

insert into aud014_single_benchmark (employee_id, payload)
select
  ('20000000-0000-0000-0000-' || lpad((value % 1000)::text, 12, '0'))::uuid,
  repeat('y', 32)
from generate_series(1, 200000) as series(value);

analyze aud014_single_benchmark;
\echo AUD014_SINGLE_BEFORE
explain (analyze, buffers, format json)
select count(*)
from aud014_single_benchmark
where employee_id = '20000000-0000-0000-0000-000000000042';

create index aud014_single_benchmark_idx
  on aud014_single_benchmark (employee_id);
analyze aud014_single_benchmark;
\echo AUD014_SINGLE_AFTER
explain (analyze, buffers, format json)
select count(*)
from aud014_single_benchmark
where employee_id = '20000000-0000-0000-0000-000000000042';

rollback;
