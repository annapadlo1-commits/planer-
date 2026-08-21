import assert from "node:assert/strict";
import test from "node:test";
import { readFile, stat } from "node:fs/promises";

const read = relative => readFile(new URL(`../${relative}`, import.meta.url), "utf8");

test("B4F-132 keeps schedule and availability in one employee section", async () => {
  const [journey,app,modules]=await Promise.all([
    read("lib/product-journey.ts"),read("app/page.tsx"),read("components/ActiveModules.tsx"),
  ]);
  const employeeNavigation=journey.slice(journey.indexOf("export const employeeNavigation"),journey.indexOf("const MANAGEMENT_ACCESS"));
  assert.doesNotMatch(employeeNavigation,/key: "availability"/);
  assert.match(employeeNavigation,/key: "my-schedule"[\s\S]*Zmiany, dostępność, urlopy i L4/);
  assert.match(app,/primarySection==="company-schedule"\?"company-schedule":primarySection==="swaps"\?"swaps":"my-schedule"/);
  assert.match(modules,/Mój grafik — \{labelMonth\(month,timezone\)\}/);
  assert.match(modules,/Wnioskuję o urlop/);
  assert.match(modules,/Zgłaszam L4/);
});

test("B4F-133 applies the accepted absence decision matrix", async () => {
  const [migration,modules]=await Promise.all([
    read("supabase/migrations/20260820225128_b4f131_b4f138_profiles_requests_notifications.sql"),
    read("components/ActiveModules.tsx"),
  ]);
  assert.match(migration,/request_type in \('LEAVE','SICKNESS','HARD_UNAVAILABLE'\)/);
  assert.match(migration,/case when v_type='LEAVE' then 'PENDING' else 'APPLIED' end/);
  assert.match(migration,/constraint_kind,time_range,source,source_record_key,[\s\S]*'SICKNESS'/);
  assert.match(migration,/if v_decision<>'ACKNOWLEDGE' then raise exception 'SICKNESS_CANNOT_BE_REJECTED'/);
  assert.match(migration,/v_legacy is null then 'AUTO_APPLIED' else 'PENDING'/);
  assert.match(modules,/L4 zapisano od razu/);
  assert.match(modules,/limit nieobecności nie jest przekroczony/);
});

test("B4F-134 and B4F-135 expose one universal action centre", async () => {
  const [component,app,migration]=await Promise.all([
    read("components/PersonalWorkspace.tsx"),read("app/page.tsx"),
    read("supabase/migrations/20260820225128_b4f131_b4f138_profiles_requests_notifications.sql"),
  ]);
  assert.match(app,/<PersonalActionNote compact\/>/);
  assert.match(app,/active==="profil"&&<UniversalPersonalWorkspace management\/>/);
  assert.match(app,/primarySection==="profile"&&\([\s\S]*<UniversalPersonalWorkspace management=\{false\}\/>/);
  assert.match(component,/Nieprzeczytane wiadomości i sprawy wymagające działania są rozdzielone/);
  assert.match(component,/L4 można wyłącznie przyjąć do wiadomości/);
  assert.match(migration,/'managerInbox'/);
  assert.match(migration,/action_required boolean not null default false/);
});

test("B4F-136, B4F-137 and B4F-146 provide a private universal profile with exactly 55 cats", async () => {
  const [component,messages,migration,extension,first,second,third]=await Promise.all([
    read("components/PersonalWorkspace.tsx"),
    read("components/MessageCenter.tsx"),
    read("supabase/migrations/20260820225128_b4f131_b4f138_profiles_requests_notifications.sql"),
    read("supabase/migrations/20260821025820_b4f146_expand_cat_avatar_catalog.sql"),
    stat(new URL("../public/profile-cats/cats-01-25-v3.png",import.meta.url)),
    stat(new URL("../public/profile-cats/cats-26-50-v3.png",import.meta.url)),
    stat(new URL("../public/profile-cats/cats-51-55-v1.png",import.meta.url)),
  ]);
  assert.match(component,/Array\.from\(\{length:55\}/);
  assert.match(component,/CAT_\$\{String\(index\+1\)\.padStart\(2,"0"\)\}/);
  assert.match(component,/const columns=second\?5:3,rows=second\?5:3/);
  assert.match(component,/cats-51-55-v1\.png/);
  assert.match(migration,/CAT_\(0\[1-9\]\|\[1-4\]\[0-9\]\|50\)/);
  assert.match(extension,/CAT_\(0\[1-9\]\|\[1-4\]\[0-9\]\|5\[0-5\]\)/);
  assert.match(migration,/bucket_id='profile-avatars'[\s\S]*auth\.uid\(\)/);
  assert.match(migration,/'senderCatAvatarKey',profile\.cat_avatar_key/);
  assert.match(migration,/'MESSAGE','TEAM_CONVERSATION'/);
  assert.match(messages,/PersonalAvatar profile=\{messageAvatar/);
  assert.match(messages,/requestedConversationId/);
  assert.ok(first.size>10_000&&second.size>10_000&&third.size>10_000);
});

test("B4F-131 renders company schedule as complete Monday-to-Sunday weeks", async () => {
  const [modules,css]=await Promise.all([
    read("components/ActiveModules.tsx"),read("app/personal-workspace.css"),
  ]);
  assert.match(modules,/const weeks=Array\.from/);
  assert.match(modules,/company-week-board/);
  assert.match(modules,/Pełne tygodnie od poniedziałku do niedzieli/);
  assert.match(css,/\.company-week-row>div\{display:grid;grid-template-columns:repeat\(7/);
  assert.match(css,/scrollbar-width:auto/);
});

test("B4F-139 and B4F-141 keep one compact Do ogarnięcia note beside Today", async () => {
  const [component,modules,css,migration]=await Promise.all([
    read("components/PersonalWorkspace.tsx"),read("components/ActiveModules.tsx"),
    read("app/personal-workspace.css"),
    read("supabase/migrations/20260821021738_employee_action_center_swap_notifications.sql"),
  ]);
  const home=modules.slice(modules.indexOf("function EmployeeHome"),modules.indexOf("function EmployeePortal"));
  assert.match(component,/DO OGARNIĘCIA/);
  assert.match(component,/!item\.resolvedAt&&\(!item\.readAt\|\|item\.actionRequired\)/);
  assert.match(home,/employee-home-top[\s\S]*<PersonalActionNote compact\/>/);
  assert.doesNotMatch(home,/employee-home-actions/);
  assert.match(css,/\.employee-home-top\{display:grid;grid-template-columns:/);
  assert.match(css,/\.personal-action-note>header>span:not\(\.personal-avatar\)\{flex:1\}/);
  assert.match(migration,/Nowa oferta na tablicy zmian/);
  assert.match(migration,/Ktoś przyjął Twoją propozycję zmiany/);
  assert.match(migration,/Zmieniono Twój grafik/);
  assert.match(migration,/Propozycja zamiany zmiany/);
});

test("B4F-142 and B4F-143 expose exact hours for every availability or absence kind", async () => {
  const [modules,css,migration]=await Promise.all([
    read("components/ActiveModules.tsx"),read("app/personal-workspace.css"),
    read("supabase/migrations/20260821021738_employee_action_center_swap_notifications.sql"),
  ]);
  assert.match(modules,/className="availability-all-day"/);
  assert.doesNotMatch(modules,/!\["PREFER_NOT_TO_WORK","LEAVE","SICKNESS"\]\.includes\(kind\)/);
  assert.match(modules,/className=\{`leave[\s\S]*onClick=\{\(\)=>setKind\("LEAVE"\)\}/);
  assert.match(modules,/className=\{`sickness[\s\S]*onClick=\{\(\)=>setKind\("SICKNESS"\)\}/);
  assert.match(modules,/employee_availability_publication_conflicts_uat_v2/);
  assert.match(modules,/employee_request_submit_uat_v2/);
  assert.match(migration,/tstzrange\(shift\.starts_at,shift\.ends_at,'\[\)'\) &&/);
  assert.match(migration,/foreach v_day in array p_dates loop/);
  assert.match(css,/\.availability-state-options\{grid-template-columns:repeat\(auto-fit,minmax\(145px,1fr\)\)!important/);
});

test("B4F-144 and B4F-145 keep seven days visible and identify coworkers with roles", async () => {
  const [modules,css]=await Promise.all([
    read("components/ActiveModules.tsx"),read("app/personal-workspace.css"),
  ]);
  assert.match(css,/\.company-week-row\{width:100%;min-width:0\}/);
  assert.match(modules,/employee-next-shift-coworkers/);
  assert.match(modules,/Z Twojej roli pracują z Tobą/);
  assert.match(modules,/calendar-coworkers/);
  assert.match(modules,/Z Tobą:/);
  assert.match(modules,/employeeName\.split\(" "\)\[0\][\s\S]*item\.roleName/);
});
