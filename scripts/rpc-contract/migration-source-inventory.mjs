import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const migrationDir = path.join(root, "supabase", "migrations");
const outputPath = process.argv[2] ? path.resolve(process.argv[2]) : null;

function splitStatements(sql) {
  const statements = [];
  let current = "";
  let state = "code";
  let dollarTag = "";
  for (let i = 0; i < sql.length; i += 1) {
    const char = sql[i];
    const next = sql[i + 1];
    if (state === "line-comment") {
      if (char === "\n") { state = "code"; current += "\n"; }
      continue;
    }
    if (state === "block-comment") {
      if (char === "*" && next === "/") { state = "code"; i += 1; current += " "; }
      continue;
    }
    if (state === "single") {
      current += char;
      if (char === "'" && next === "'") { current += next; i += 1; }
      else if (char === "'") state = "code";
      continue;
    }
    if (state === "double") {
      current += char;
      if (char === '"' && next === '"') { current += next; i += 1; }
      else if (char === '"') state = "code";
      continue;
    }
    if (state === "dollar") {
      current += char;
      if (sql.startsWith(dollarTag, i)) {
        current += dollarTag.slice(1);
        i += dollarTag.length - 1;
        state = "code";
      }
      continue;
    }
    if (char === "-" && next === "-") { state = "line-comment"; i += 1; continue; }
    if (char === "/" && next === "*") { state = "block-comment"; i += 1; continue; }
    if (char === "'") { state = "single"; current += char; continue; }
    if (char === '"') { state = "double"; current += char; continue; }
    if (char === "$") {
      const match = sql.slice(i).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) { dollarTag = match[0]; state = "dollar"; current += dollarTag; i += dollarTag.length - 1; continue; }
    }
    current += char;
    if (char === ";") { if (current.trim()) statements.push(current.trim()); current = ""; }
  }
  if (current.trim()) statements.push(current.trim());
  return statements;
}

function splitTopLevel(text) {
  const parts = [];
  let current = "";
  let depth = 0;
  let single = false;
  let double = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    const next = text[i + 1];
    if (single) {
      current += char;
      if (char === "'" && next === "'") { current += next; i += 1; }
      else if (char === "'") single = false;
      continue;
    }
    if (double) {
      current += char;
      if (char === '"' && next === '"') { current += next; i += 1; }
      else if (char === '"') double = false;
      continue;
    }
    if (char === "'") { single = true; current += char; continue; }
    if (char === '"') { double = true; current += char; continue; }
    if ("([{".includes(char)) depth += 1;
    if (")] }".replace(" ", "").includes(char)) depth -= 1;
    if (char === "," && depth === 0) { parts.push(current.trim()); current = ""; }
    else current += char;
  }
  if (current.trim()) parts.push(current.trim());
  return parts;
}

function normalizeIdentifier(value) {
  return value.trim().replaceAll('"', "").toLowerCase();
}

function normalizeType(value) {
  let type = value.trim().replace(/\s+/g, " ").replaceAll('"', "").toLowerCase();
  type = type.replace(/^public\./, "").replace(/^pg_catalog\./, "");
  const array = type.endsWith("[]") ? "[]" : "";
  if (array) type = type.slice(0, -2).trim();
  const aliases = new Map([
    ["int", "integer"], ["int4", "integer"], ["smallint", "smallint"], ["int2", "smallint"],
    ["bigint", "bigint"], ["int8", "bigint"], ["bool", "boolean"], ["float8", "double precision"],
    ["float4", "real"], ["decimal", "numeric"], ["varchar", "character varying"],
    ["timestamptz", "timestamp with time zone"], ["timestamp", "timestamp without time zone"],
    ["timetz", "time with time zone"], ["time", "time without time zone"],
  ]);
  return (aliases.get(type) ?? type) + array;
}

function findClosingParen(text, open) {
  let depth = 0;
  let single = false;
  let double = false;
  for (let i = open; i < text.length; i += 1) {
    const char = text[i];
    if (single) { if (char === "'" && text[i + 1] === "'") i += 1; else if (char === "'") single = false; continue; }
    if (double) { if (char === '"' && text[i + 1] === '"') i += 1; else if (char === '"') double = false; continue; }
    if (char === "'") { single = true; continue; }
    if (char === '"') { double = true; continue; }
    if (char === "(") depth += 1;
    if (char === ")") { depth -= 1; if (depth === 0) return i; }
  }
  return -1;
}

function parseCreate(statement) {
  const prefix = statement.match(/^create\s+(?:or\s+replace\s+)?function\s+/i);
  if (!prefix) return null;
  const open = statement.indexOf("(", prefix[0].length);
  if (open < 0) return null;
  const close = findClosingParen(statement, open);
  if (close < 0) return null;
  const qualified = normalizeIdentifier(statement.slice(prefix[0].length, open));
  const nameParts = qualified.split(".");
  const name = nameParts.pop();
  const schema = nameParts.pop() ?? "public";
  const args = splitTopLevel(statement.slice(open + 1, close)).map((raw) => {
    const withoutMode = raw.replace(/^\s*(?:inout|in|variadic)\s+/i, "").trim();
    const mode = (raw.match(/^\s*(out|inout|in|variadic)\s+/i)?.[1] ?? "in").toLowerCase();
    const defaultMatch = withoutMode.match(/\s+(?:default\s+|=\s*)([\s\S]*)$/i);
    const core = (defaultMatch ? withoutMode.slice(0, defaultMatch.index) : withoutMode).trim();
    const firstSpace = core.search(/\s/);
    if (firstSpace < 0) return { name: null, type: normalizeType(core), hasDefault: Boolean(defaultMatch), mode };
    const first = normalizeIdentifier(core.slice(0, firstSpace));
    const rest = core.slice(firstSpace).trim();
    const typeLeaders = /^(?:smallint|integer|bigint|decimal|numeric|real|double|boolean|char|varchar|character|text|bytea|timestamp|timestamptz|date|time|timetz|interval|uuid|json|jsonb|xml|inet|cidr|macaddr|bit|varbit|money|oid|record|anyelement|anyarray|anycompatible|public\.)$/i;
    if (typeLeaders.test(first)) return { name: null, type: normalizeType(core), hasDefault: Boolean(defaultMatch), mode };
    return { name: first, type: normalizeType(rest), hasDefault: Boolean(defaultMatch), mode };
  }).filter((arg) => !["out"].includes(arg.mode));
  const tail = statement.slice(close + 1);
  const returnMatch = tail.match(/\breturns\s+([\s\S]*?)(?=\s+(?:language|stable|immutable|volatile|security|parallel|cost|rows|set\s+search_path|as)\b)/i);
  const returnType = returnMatch ? returnMatch[1].trim().replace(/\s+/g, " ").toLowerCase() : null;
  return { schema, name, args, returnType, securityDefiner: /\bsecurity\s+definer\b/i.test(tail) };
}

function parseFunctionSpecs(text) {
  return splitTopLevel(text).map((raw) => {
    const cleaned = raw.replace(/\s+(?:cascade|restrict)\s*$/i, "").trim();
    const open = cleaned.indexOf("(");
    if (open < 0) {
      const parts = normalizeIdentifier(cleaned).split(".");
      return { schema: parts.length > 1 ? parts.at(-2) : "public", name: parts.at(-1), types: null };
    }
    const close = findClosingParen(cleaned, open);
    const parts = normalizeIdentifier(cleaned.slice(0, open)).split(".");
    // PostgreSQL pg_get_function_identity_arguments includes argument names.
    // GRANT/REVOKE accept both named arguments and bare types. Parse them with
    // the same mode/type rules as CREATE, not as a type named "p_rows jsonb".
    const parsed = parseCreate(`create function ${cleaned.slice(0, close + 1)} returns void language sql`);
    return { schema: parts.length > 1 ? parts.at(-2) : "public", name: parts.at(-1), types: parsed.args.map(arg => arg.type) };
  });
}

const functions = new Map();
const files = fs.readdirSync(migrationDir).filter((name) => name.endsWith(".sql")).sort();
let statementCount = 0;
function keyOf(definition) { return `${definition.schema}.${definition.name}(${definition.args.map((arg) => arg.type).join(",")})`; }
function matchingKeys(spec) {
  return [...functions.keys()].filter((key) => {
    const value = functions.get(key);
    return value.schema === spec.schema && value.name === spec.name && (spec.types === null || JSON.stringify(value.args.map((arg) => arg.type)) === JSON.stringify(spec.types));
  });
}

for (const file of files) {
  const sql = fs.readFileSync(path.join(migrationDir, file), "utf8");
  for (const statement of splitStatements(sql)) {
    statementCount += 1;
    const created = parseCreate(statement);
    if (created) {
      const key = keyOf(created);
      const previous = functions.get(key);
      functions.set(key, { ...created, key, sourceFile: file, publicDirect: previous?.publicDirect ?? true, anonDirect: previous?.anonDirect ?? false, authenticatedDirect: previous?.authenticatedDirect ?? false });
      continue;
    }
    const drop = statement.match(/^drop\s+function\s+(?:if\s+exists\s+)?([\s\S]*?);?$/i);
    if (drop) { for (const spec of parseFunctionSpecs(drop[1])) for (const key of matchingKeys(spec)) functions.delete(key); continue; }
    const rename = statement.match(/^alter\s+function\s+([\s\S]*?)\s+rename\s+to\s+([\w"]+)\s*;?$/i);
    if (rename) {
      for (const spec of parseFunctionSpecs(rename[1])) for (const key of matchingKeys(spec)) {
        const definition = { ...functions.get(key), name: normalizeIdentifier(rename[2]) };
        functions.delete(key);
        definition.key = keyOf(definition);
        functions.set(definition.key, definition);
      }
      continue;
    }
    const privilege = statement.match(/^(grant|revoke)\s+(?:all(?:\s+privileges)?|execute)\s+on\s+function\s+([\s\S]*?)\s+(?:to|from)\s+([\s\S]*?);?$/i);
    if (privilege) {
      const grant = privilege[1].toLowerCase() === "grant";
      const roles = splitTopLevel(privilege[3].replace(/;$/, "")).map(normalizeIdentifier);
      for (const spec of parseFunctionSpecs(privilege[2])) for (const key of matchingKeys(spec)) {
        const definition = functions.get(key);
        if (roles.includes("public")) definition.publicDirect = grant;
        if (roles.includes("anon")) definition.anonDirect = grant;
        if (roles.includes("authenticated")) definition.authenticatedDirect = grant;
      }
      continue;
    }
    if (/^do\s+\$/i.test(statement)
      && /namespace_row\.nspname\s*=\s*'public'/i.test(statement)
      && /procedure_row\.prosecdef/i.test(statement)
      && /revoke execute on function %s from public,anon/i.test(statement)) {
      for (const definition of functions.values()) {
        if (definition.schema !== "public" || !definition.securityDefiner) continue;
        const authenticatedPreviouslyEffective = definition.publicDirect || definition.authenticatedDirect;
        definition.publicDirect = false;
        definition.anonDirect = false;
        if (authenticatedPreviouslyEffective) definition.authenticatedDirect = true;
      }
    }
  }
}

const inventory = [...functions.values()].map((definition) => ({
  ...definition,
  publicExecute: definition.publicDirect,
  anonExecute: definition.publicDirect || definition.anonDirect,
  authenticatedExecute: definition.publicDirect || definition.authenticatedDirect,
})).sort((a, b) => a.key.localeCompare(b.key));
const report = { generatedFrom: "ordered canonical migration DDL statements", migrationFiles: files.length, statementsParsed: statementCount, functionOverloads: inventory.length, inventory };
const serialized = `${JSON.stringify(report, null, 2)}\n`;
if (outputPath) fs.writeFileSync(outputPath, serialized);
process.stdout.write(serialized);
