import type { SupabaseClient } from "@supabase/supabase-js";
import type { MatrixV2Workspace } from "./matrix-v2";

export type MonthlyBudgetLine = {
  id?: string;
  scopeType: "COMPANY" | "LOCATION" | "CATEGORY" | "LOCATION_CATEGORY" | "ROLE";
  locationLogicalId?: string | null;
  categoryLogicalId?: string | null;
  roleLogicalId?: string | null;
  locationId?: string | null;
  categoryId?: string | null;
  roleId?: string | null;
  metricType: "COST" | "HOURS" | "LABOR_PERCENT";
  enforcement: "HARD" | "TARGET" | "MONITORING";
  limitValue: number;
  referenceValue?: number | null;
  currency?: string | null;
  costBasis?: "WAGES" | "FULL_EMPLOYER_COST" | null;
  distributionMode?: "MONTHLY" | "AUTO" | "MANUAL";
  distribution?: Record<string, number> | null;
};

export type MonthlyBudgetWorkspace = {
  month: string;
  canEdit: boolean;
  revision: null | { id: string; number: number; note?: string | null; createdAt: string };
  lines: MonthlyBudgetLine[];
};

export function hydrateMonthlyBudgetLines(
  lines: MonthlyBudgetLine[],
  matrix: MatrixV2Workspace | null,
): MonthlyBudgetLine[] {
  return lines.map((line) => ({
    ...line,
    locationId: matrix?.locations.find((item) => item.logicalId === line.locationLogicalId)?.id ?? null,
    categoryId: matrix?.roleCategories?.find((item) => item.logicalId === line.categoryLogicalId)?.id ?? null,
    roleId: matrix?.roles.find((item) => item.logicalId === line.roleLogicalId)?.id ?? null,
  }));
}

function rpcError(name: string, error: { code?: string; message?: string; details?: string; hint?: string }) {
  return new Error([name, error.code, error.message, error.details, error.hint].filter(Boolean).join(":"));
}

export async function getMonthlyBudgets(client: SupabaseClient, month: string) {
  const result = await client.rpc("monthly_budgets_get_uat_v1", { p_month: `${month.slice(0, 7)}-01` });
  if (result.error) throw rpcError("MONTHLY_BUDGETS_GET", result.error);
  return result.data as MonthlyBudgetWorkspace;
}

export async function saveMonthlyBudgets(client: SupabaseClient, month: string, lines: MonthlyBudgetLine[], note: string) {
  const result = await client.rpc("monthly_budgets_save_uat_v1", {
    p_month: `${month.slice(0, 7)}-01`, p_lines: lines, p_note: note,
  });
  if (result.error) throw rpcError("MONTHLY_BUDGETS_SAVE", result.error);
  return result.data as MonthlyBudgetWorkspace;
}
