import type { SolverRole, SolverRoleCategory } from "@/lib/solver-v2";

export type WorkspaceAccessRole = {
  app_role: string;
  role_logical_id?: string | null;
};

export type WorkspaceAccessPolicy = {
  canManageCompanySchedule: boolean;
  canReadCompanyWorkspace: boolean;
  canReadFullEmployeeDirectory: boolean;
  canReadManagementOperations: boolean;
  exactRoleScopeLogicalIds: ReadonlySet<string>;
};

export function workspaceAccessPolicy(roles: readonly WorkspaceAccessRole[] = []): WorkspaceAccessPolicy {
  const hasRole = (...allowed: string[]) => roles.some(item => allowed.includes(item.app_role));
  return {
    canManageCompanySchedule: hasRole("OWNER", "ADMIN"),
    canReadCompanyWorkspace: hasRole("OWNER", "ADMIN", "HR_FINANCE", "VERIFIER"),
    canReadFullEmployeeDirectory: hasRole("OWNER", "ADMIN", "HR_FINANCE"),
    canReadManagementOperations: hasRole(
      "OWNER", "ADMIN", "HR_FINANCE", "VERIFIER", "ROLE_MANAGER", "LOCATION_MANAGER",
    ),
    exactRoleScopeLogicalIds: new Set(
      roles
        .filter(item => item.app_role === "ROLE_MANAGER" && item.role_logical_id)
        .map(item => item.role_logical_id as string),
    ),
  };
}

export function canManageWholeSolverCategory(
  policy: WorkspaceAccessPolicy,
  solverRoles: readonly SolverRole[],
  category: SolverRoleCategory,
) {
  if (policy.canManageCompanySchedule) return true;
  if (!category.roleIds.length) return false;
  return category.roleIds.every(roleId => {
    const logicalId = solverRoles.find(role => role.id === roleId)?.logicalId;
    return Boolean(logicalId && policy.exactRoleScopeLogicalIds.has(logicalId));
  });
}

export function shouldRestoreCategoryGenerator(
  modalOpen: boolean,
  currentCategoryId: string | null,
  savedCategoryId: string,
) {
  return !modalOpen || currentCategoryId !== savedCategoryId;
}
