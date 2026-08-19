import type { ReactNode } from "react";
import { ChevronDown } from "lucide-react";

type CheckboxDropdownProps = {
  label: string;
  selectedCount: number;
  totalCount: number;
  children: ReactNode;
  className?: string;
};

export function CheckboxDropdown({ label, selectedCount, totalCount, children, className = "" }: CheckboxDropdownProps) {
  const selection = selectedCount === 0
    ? "Wszystkie"
    : selectedCount === totalCount
      ? `Wszystkie (${totalCount})`
      : `${selectedCount} z ${totalCount}`;

  return <details className={`checkbox-dropdown ${className}`.trim()}>
    <summary>
      <span><small>{label}</small><strong>{selection}</strong></span>
      <ChevronDown aria-hidden="true" />
    </summary>
    <fieldset>
      <legend>{label}</legend>
      {children}
    </fieldset>
  </details>;
}
