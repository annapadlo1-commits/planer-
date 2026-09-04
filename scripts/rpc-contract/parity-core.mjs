function inputArgs(definition) {
  if (Array.isArray(definition.args)) {
    return definition.args.filter((argument) => !argument.mode || argument.mode === "in" || argument.mode === "inout");
  }
  const names = Array.isArray(definition.input_arg_names) ? definition.input_arg_names : [];
  const types = Array.isArray(definition.input_arg_types) ? definition.input_arg_types.filter(Boolean) : [];
  const defaultCount = Number(definition.pronargdefaults ?? 0);
  return types.map((type, index) => ({
    name: names[index] ?? null,
    type,
    hasDefault: index >= types.length - defaultCount,
    mode: "in",
  }));
}

function schemaOf(definition) {
  return definition.schema ?? definition.schema_name;
}

function authExecute(definition) {
  return Boolean(definition.authenticatedExecute ?? definition.authenticated_execute);
}

function anonExecute(definition) {
  return Boolean(definition.anonExecute ?? definition.anon_execute);
}

function publicExecute(definition) {
  return Boolean(definition.publicExecute ?? definition.public_execute);
}

export function signature(definition) {
  return `${schemaOf(definition)}.${definition.name}(${inputArgs(definition).map((argument) => `${argument.name ?? "?"}:${argument.type}${argument.hasDefault ? "=?" : ""}`).join(",")})`;
}

export function callShapeMatches(definition, payloadShape) {
  if (payloadShape.dynamic) return false;
  const supplied = new Set(payloadShape.keys);
  const args = inputArgs(definition);
  const available = new Set(args.map((argument) => argument.name).filter(Boolean));
  if ([...supplied].some((name) => !available.has(name))) return false;
  return args.every((argument) => argument.hasDefault || supplied.has(argument.name));
}

export function classifyInventory(frontendInventory, definitions) {
  const matrix = frontendInventory.map((rpc) => {
    const named = definitions.filter((definition) => definition.name === rpc.name);
    const publicDefinitions = named.filter((definition) => schemaOf(definition) === "public");
    const matchesByPayload = rpc.payloadShapes.map((shape) =>
      publicDefinitions.filter((definition) => callShapeMatches(definition, shape)));
    const compatible = [...new Set(matchesByPayload.flat())];
    const everyPayloadMatches = matchesByPayload.length > 0
      && matchesByPayload.every((matches) => matches.length > 0);
    let classification = "MATCHED";
    if (named.length === 0) classification = "MISSING";
    else if (publicDefinitions.length === 0) classification = "WRONG_SCHEMA";
    else if (!everyPayloadMatches) classification = "SIGNATURE_MISMATCH";
    else if (compatible.some((definition) => !authExecute(definition))) classification = "AUTH_GRANT_MISMATCH";
    else if (compatible.some((definition) => anonExecute(definition) || publicExecute(definition))) classification = "UNEXPECTED_ANON";

    return {
      rpc: rpc.name,
      classification,
      exists: named.length > 0,
      publicSchema: publicDefinitions.length > 0,
      signatureMatch: everyPayloadMatches,
      authenticatedExecute: compatible.length > 0 && compatible.every(authExecute),
      anonymousExecute: compatible.some((definition) => anonExecute(definition) || publicExecute(definition)),
      frontendPayloads: rpc.payloadShapes,
      signatures: publicDefinitions.map(signature),
      callSites: rpc.callSites,
      testReferences: rpc.testReferences,
    };
  });
  const classes = ["MATCHED", "MISSING", "SIGNATURE_MISMATCH", "WRONG_SCHEMA", "AUTH_GRANT_MISMATCH", "UNEXPECTED_ANON"];
  const counts = Object.fromEntries(classes.map((classification) => [classification, matrix.filter((row) => row.classification === classification).length]));
  return { counts, matrix };
}

export function compareSourceAndLive(sourceDefinitions, liveDefinitions, frontendNames) {
  const names = new Set(frontendNames);
  const source = sourceDefinitions.filter((definition) => names.has(definition.name) && schemaOf(definition) === "public");
  const live = liveDefinitions.filter((definition) => names.has(definition.name) && schemaOf(definition) === "public");
  const sourceSet = new Set(source.map(signature));
  const liveSet = new Set(live.map(signature));
  return {
    sourceOnly: [...sourceSet].filter((value) => !liveSet.has(value)).sort(),
    liveOnly: [...liveSet].filter((value) => !sourceSet.has(value)).sort(),
  };
}

export function assertParity(result, label) {
  const failures = result.matrix.filter((row) => row.classification !== "MATCHED");
  if (failures.length) {
    const details = failures.map((row) => `${row.rpc}: ${row.classification}`).join("\n");
    throw new Error(`${label} parity failed (${failures.length}):\n${details}`);
  }
}
