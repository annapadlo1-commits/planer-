import type { SupabaseClient } from "@supabase/supabase-js";

export type EmployerCostComponent = {
  id: string; logicalId: string; revision: number; code: string; name: string;
  calculationMethod: "PERCENT_BASE" | "PER_HOUR" | "FIXED_PER_SHIFT";
  percentBasisPoints?: number | null; rateMinorPerHour?: number | null; amountMinor?: number | null;
  contractType?: string | null; validFrom: string; validTo?: string | null; active: boolean; reason: string;
};

export async function getEmployerCostComponents(client: SupabaseClient, month: string) {
  const { data, error } = await client.rpc("employer_cost_workspace_uat_v1", { p_month: month });
  if (error) throw error;
  return (data?.components ?? []) as EmployerCostComponent[];
}

export async function saveEmployerCostComponent(client: SupabaseClient, item: {
  logicalId?: string | null; code: string; name: string; calculationMethod: EmployerCostComponent["calculationMethod"];
  value: number; contractType?: string | null; validFrom: string; validTo?: string | null; active: boolean; reason: string;
}) {
  const { data, error } = await client.rpc("employer_cost_component_save_uat_v1", {
    p_logical_id: item.logicalId ?? null, p_code: item.code, p_name: item.name,
    p_calculation_method: item.calculationMethod, p_value: item.value,
    p_contract_type: item.contractType || null, p_valid_from: item.validFrom,
    p_valid_to: item.validTo || null, p_active: item.active, p_reason: item.reason,
  });
  if (error) throw error;
  return String(data);
}
