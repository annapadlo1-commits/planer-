-- Publication helper predicates used by the complete Matrix v2 validator.
-- Kept in a preceding migration so a clean replay never exposes an unresolved
-- validator dependency.

create or replace function public.matrix_v2_is_iso_4217_currency(p_currency text)
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select p_currency ~ '^[A-Z]{3}$' and position(
    ' '||p_currency||' ' in
    ' AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWG ZWL '
  ) > 0;
$$;

create or replace function public.matrix_v2_is_supported_pay_condition(
  p_condition jsonb
) returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_condition)<>'object'
      or p_condition-array['field','operator','value']<>'{}'::jsonb
      or not (p_condition ? 'field' and p_condition ? 'operator'
        and p_condition ? 'value')
      then false
    when lower(p_condition->>'field') in (
      'role_id','location_id','shift_template_id','scenario_id','employee_id'
    ) then case upper(p_condition->>'operator')
      when 'EQ' then jsonb_typeof(p_condition->'value')='string'
        and (p_condition->>'value')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when 'NE' then jsonb_typeof(p_condition->'value')='string'
        and (p_condition->>'value')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when 'IN' then jsonb_typeof(p_condition->'value')='array' and not exists(
        select 1 from jsonb_array_elements(p_condition->'value') item
        where jsonb_typeof(item.value)<>'string'
          or (item.value#>>'{}')
            !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array' and not exists(
        select 1 from jsonb_array_elements(p_condition->'value') item
        where jsonb_typeof(item.value)<>'string'
          or (item.value#>>'{}')
            !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      else false end
    when lower(p_condition->>'field')='duty_ids' then
      case upper(p_condition->>'operator')
        when 'CONTAINS' then jsonb_typeof(p_condition->'value')='string'
          and (p_condition->>'value')
            ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        when 'CONTAINS_ANY' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or (item.value#>>'{}')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          )
        when 'CONTAINS_ALL' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or (item.value#>>'{}')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          )
        else false end
    when lower(p_condition->>'field')='contract_code' then
      case upper(p_condition->>'operator')
        when 'EQ' then jsonb_typeof(p_condition->'value')='string'
          and length(p_condition->>'value')>0
        when 'NE' then jsonb_typeof(p_condition->'value')='string'
          and length(p_condition->>'value')>0
        when 'IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or length(item.value#>>'{}')=0
          )
        when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or length(item.value#>>'{}')=0
          )
        else false end
    when lower(p_condition->>'field') in ('weekday','duration_minutes') then
      case upper(p_condition->>'operator')
        when 'EQ' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'NE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'GTE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'LTE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'number'
              or (item.value#>>'{}') !~ '^[0-9]+$'
              or (lower(p_condition->>'field')='weekday'
                and (item.value#>>'{}')::integer not between 1 and 7)
          )
        when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'number'
              or (item.value#>>'{}') !~ '^[0-9]+$'
              or (lower(p_condition->>'field')='weekday'
                and (item.value#>>'{}')::integer not between 1 and 7)
          )
        else false end
    when lower(p_condition->>'field')='local_time' then
      upper(p_condition->>'operator')='OVERLAPS_TIME'
      and jsonb_typeof(p_condition->'value')='object'
      and (p_condition->'value')-array['start','end']<>'{}'::jsonb
      and coalesce(p_condition->'value'->>'start','')
        ~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
      and coalesce(p_condition->'value'->>'end','')
        ~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
    else false
  end;
$$;

revoke all on function public.matrix_v2_is_iso_4217_currency(text),
  public.matrix_v2_is_supported_pay_condition(jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_is_iso_4217_currency(text),
  public.matrix_v2_is_supported_pay_condition(jsonb)
  to service_role;
