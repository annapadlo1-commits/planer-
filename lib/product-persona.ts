import { useEffect, useMemo, useRef, useState } from "react";

import {
  availablePersonas,
  defaultPersonaForAccess,
  reconcilePersona,
  type AppPersona,
  type PersonaEmployee,
} from "@/lib/product-journey";

export function useProductPersona(
  roles: { app_role: string }[] | null | undefined,
  employee: PersonaEmployee,
) {
  const personas = useMemo(() => availablePersonas(roles, employee), [employee, roles]);
  const [activePersona, setActivePersona] = useState<AppPersona>(() => defaultPersonaForAccess(roles, employee) ?? "management");
  const explicitlySelected = useRef(false);
  useEffect(() => {
    const safePersona = reconcilePersona(activePersona, roles, employee, explicitlySelected.current);
    if (safePersona && safePersona !== activePersona) setActivePersona(safePersona);
  }, [activePersona, employee, personas, roles]);
  const selectPersona = (persona: AppPersona) => {
    explicitlySelected.current = true;
    setActivePersona(persona);
  };
  return { activePersona, employeeShell: activePersona === "employee" && personas.includes("employee"), personas, selectPersona };
}
