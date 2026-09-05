import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

const root = process.cwd();
const outputPath = process.argv[2] ? path.resolve(process.argv[2]) : null;
const roots = ["app", "components", "lib"];
const rootFiles = ["proxy.ts", "middleware.ts"].filter((name) => fs.existsSync(path.join(root, name)));

function walk(directory) {
  if (!fs.existsSync(directory)) return [];
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (!["node_modules", ".next", "tests", "__tests__", "docs", "work"].includes(entry.name)) result.push(...walk(full));
    } else if (/\.(?:ts|tsx)$/.test(entry.name) && !/\.(?:test|spec)\.(?:ts|tsx)$/.test(entry.name) && !entry.name.endsWith(".d.ts")) {
      result.push(full);
    }
  }
  return result;
}

function walkTests(directory) {
  if (!fs.existsSync(directory)) return [];
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (!['node_modules', '.next'].includes(entry.name)) result.push(...walkTests(full));
    } else if (/\.(?:[cm]?js|jsx|ts|tsx)$/.test(entry.name)) {
      result.push(full);
    }
  }
  return result;
}

const files = [...roots.flatMap((name) => walk(path.join(root, name))), ...rootFiles.map((name) => path.join(root, name))].sort();
const sourceFiles = new Map();
const constInitializers = new Map();

for (const file of files) {
  const source = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
  sourceFiles.set(file, source);
  const constants = new Map();
  function collect(node) {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) constants.set(node.name.text, node.initializer);
    ts.forEachChild(node, collect);
  }
  collect(source);
  constInitializers.set(file, constants);
}

function unwrap(node) {
  while (node && (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isTypeAssertionExpression(node) || ts.isNonNullExpression(node) || ts.isSatisfiesExpression?.(node))) node = node.expression;
  return node;
}

function resolveInitializer(file, node, seen = new Set()) {
  node = unwrap(node);
  if (node && ts.isIdentifier(node) && !seen.has(node.text)) {
    seen.add(node.text);
    const next = constInitializers.get(file)?.get(node.text);
    if (next) return resolveInitializer(file, next, seen);
  }
  return node;
}

function booleanFormula(file, node, seen = new Set()) {
  node = unwrap(node);
  if (!node) return { kind: "constant", value: false };
  if (node.kind === ts.SyntaxKind.TrueKeyword) return { kind: "constant", value: true };
  if (node.kind === ts.SyntaxKind.FalseKeyword) return { kind: "constant", value: false };
  if (ts.isIdentifier(node)) {
    const next = constInitializers.get(file)?.get(node.text);
    if (next && !seen.has(node.text)) {
      const nextSeen = new Set(seen);
      nextSeen.add(node.text);
      return booleanFormula(file, next, nextSeen);
    }
    return { kind: "atom", key: `identifier:${node.text}` };
  }
  if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.ExclamationToken) {
    return { kind: "not", operand: booleanFormula(file, node.operand, seen) };
  }
  if (ts.isBinaryExpression(node)) {
    if (node.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
      return { kind: "and", left: booleanFormula(file, node.left, seen), right: booleanFormula(file, node.right, seen) };
    }
    if (node.operatorToken.kind === ts.SyntaxKind.BarBarToken) {
      return { kind: "or", left: booleanFormula(file, node.left, seen), right: booleanFormula(file, node.right, seen) };
    }
  }
  const source = sourceFiles.get(file);
  const expression = source ? node.getText(source).replace(/\s+/gu, " ") : String(node.kind);
  return { kind: "atom", key: `expression:${expression}` };
}

function negate(formula) {
  return { kind: "not", operand: formula };
}

function collectAtoms(formula, atoms) {
  if (formula.kind === "atom") atoms.add(formula.key);
  else if (formula.kind === "not") collectAtoms(formula.operand, atoms);
  else if (formula.kind === "and" || formula.kind === "or") {
    collectAtoms(formula.left, atoms);
    collectAtoms(formula.right, atoms);
  }
}

function evaluateFormula(formula, assignment) {
  if (formula.kind === "constant") return formula.value;
  if (formula.kind === "atom") return assignment.get(formula.key) ?? false;
  if (formula.kind === "not") return !evaluateFormula(formula.operand, assignment);
  if (formula.kind === "and") return evaluateFormula(formula.left, assignment) && evaluateFormula(formula.right, assignment);
  return evaluateFormula(formula.left, assignment) || evaluateFormula(formula.right, assignment);
}

function conditionsAreSatisfiable(conditions) {
  const atomSet = new Set();
  for (const condition of conditions) collectAtoms(condition, atomSet);
  const atoms = [...atomSet];
  if (atoms.length > 16) return true;
  for (let mask = 0; mask < 2 ** atoms.length; mask += 1) {
    const assignment = new Map(atoms.map((atom, index) => [atom, Boolean(mask & (2 ** index))]));
    if (conditions.every((condition) => evaluateFormula(condition, assignment))) return true;
  }
  return false;
}

function staticStringVariants(file, node, conditions = []) {
  node = resolveInitializer(file, node);
  if (node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node))) {
    return [{ value: node.text, conditions }];
  }
  if (node && ts.isConditionalExpression(node)) {
    const condition = booleanFormula(file, node.condition);
    return [
      ...staticStringVariants(file, node.whenTrue, [...conditions, condition]),
      ...staticStringVariants(file, node.whenFalse, [...conditions, negate(condition)]),
    ];
  }
  return [];
}

function payloadVariants(file, node, conditions = []) {
  if (!node) return [{ keys: [], dynamic: false, conditions }];
  node = resolveInitializer(file, node);
  if (node && ts.isConditionalExpression(node)) {
    const condition = booleanFormula(file, node.condition);
    return [
      ...payloadVariants(file, node.whenTrue, [...conditions, condition]),
      ...payloadVariants(file, node.whenFalse, [...conditions, negate(condition)]),
    ];
  }
  if (!node || !ts.isObjectLiteralExpression(node)) return [{ keys: [], dynamic: true, conditions }];
  let variants = [{ keys: [], dynamic: false, conditions }];
  for (const property of node.properties) {
    if (ts.isSpreadAssignment(property)) {
      const spreadVariants = payloadVariants(file, property.expression);
      variants = variants.flatMap((base) => spreadVariants.map((spread) => ({
        keys: [...new Set([...base.keys, ...spread.keys])].sort(),
        dynamic: base.dynamic || spread.dynamic,
        conditions: [...base.conditions, ...spread.conditions],
      })));
      continue;
    }
    const name = property.name;
    if (!name) continue;
    if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) {
      variants = variants.map((variant) => ({ ...variant, keys: [...new Set([...variant.keys, name.text])].sort() }));
    } else variants = variants.map((variant) => ({ ...variant, dynamic: true }));
  }
  return variants.filter((variant, index, all) => all.findIndex((candidate) => JSON.stringify(candidate) === JSON.stringify(variant)) === index);
}

function functionName(node) {
  if (ts.isFunctionDeclaration(node) && node.name) return node.name.text;
  if ((ts.isArrowFunction(node) || ts.isFunctionExpression(node)) && ts.isVariableDeclaration(node.parent) && ts.isIdentifier(node.parent.name)) return node.parent.name.text;
  if ((ts.isArrowFunction(node) || ts.isFunctionExpression(node))
    && ts.isCallExpression(node.parent)
    && ts.isVariableDeclaration(node.parent.parent)
    && ts.isIdentifier(node.parent.parent.name)) return node.parent.parent.name.text;
  return null;
}

const wrappersByFile = new Map();
for (const [file, source] of sourceFiles) {
  const wrappers = new Map();
  function visitFunction(node) {
    if (ts.isFunctionLike(node)) {
      const name = functionName(node);
      const params = node.parameters.map((parameter) => ts.isIdentifier(parameter.name) ? parameter.name.text : null);
      if (name && params.length) {
        function findRpc(candidate) {
          if (ts.isCallExpression(candidate) && ts.isPropertyAccessExpression(candidate.expression) && candidate.expression.name.text === "rpc") {
            const first = unwrap(candidate.arguments[0]);
            if (first && ts.isIdentifier(first)) {
              const rpcNameIndex = params.indexOf(first.text);
              if (rpcNameIndex >= 0) {
                const second = unwrap(candidate.arguments[1]);
                const payloadIndex = second && ts.isIdentifier(second) ? params.indexOf(second.text) : -1;
                wrappers.set(name, { rpcNameIndex, payloadIndex });
              }
            }
          }
          ts.forEachChild(candidate, findRpc);
        }
        if (node.body) findRpc(node.body);
      }
    }
    ts.forEachChild(node, visitFunction);
  }
  visitFunction(source);
  wrappersByFile.set(file, wrappers);
}

const calls = [];
const unresolved = [];
for (const [file, source] of sourceFiles) {
  const wrappers = wrappersByFile.get(file) ?? new Map();
  const relative = path.relative(root, file).replaceAll("\\", "/");
  function add(nameVariant, node, payloads, via) {
    const position = source.getLineAndCharacterOfPosition(node.getStart(source));
    const correlatedPayloads = payloads
      .filter((payload) => conditionsAreSatisfiable([...nameVariant.conditions, ...payload.conditions]))
      .map(({ keys, dynamic }) => ({ keys, dynamic }))
      .filter((payload, index, all) => all.findIndex((candidate) => JSON.stringify(candidate) === JSON.stringify(payload)) === index);
    calls.push({ name: nameVariant.value, file: relative, line: position.line + 1, payloadVariants: correlatedPayloads, via });
  }
  function visit(node) {
    if (ts.isCallExpression(node)) {
      if (ts.isPropertyAccessExpression(node.expression) && node.expression.name.text === "rpc") {
        const names = staticStringVariants(file, node.arguments[0]);
        const isWrapperBody = [...wrappers.values()].some((wrapper) => {
          const first = unwrap(node.arguments[0]);
          return first && ts.isIdentifier(first) && wrapper.rpcNameIndex >= 0;
        });
        if (names.length) for (const name of names) add(name, node, payloadVariants(file, node.arguments[1]), "direct");
        else if (!isWrapperBody) {
          const position = source.getLineAndCharacterOfPosition(node.getStart(source));
          unresolved.push({ file: relative, line: position.line + 1, expression: node.arguments[0]?.getText(source) ?? "<missing>" });
        }
      } else if (ts.isIdentifier(node.expression) && wrappers.has(node.expression.text)) {
        const wrapper = wrappers.get(node.expression.text);
        const names = staticStringVariants(file, node.arguments[wrapper.rpcNameIndex]);
        if (names.length) for (const name of names) add(name, node, payloadVariants(file, wrapper.payloadIndex >= 0 ? node.arguments[wrapper.payloadIndex] : undefined), `wrapper:${node.expression.text}`);
        else {
          const position = source.getLineAndCharacterOfPosition(node.getStart(source));
          unresolved.push({ file: relative, line: position.line + 1, expression: `${node.expression.text}(${node.arguments[wrapper.rpcNameIndex]?.getText(source) ?? "<missing>"})` });
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
}

const tests = walkTests(path.join(root, "tests"));
const testText = new Map(tests.map((file) => [path.relative(root, file).replaceAll("\\", "/"), fs.readFileSync(file, "utf8")]));
const grouped = new Map();
for (const call of calls) {
  if (!grouped.has(call.name)) grouped.set(call.name, { name: call.name, callSites: [], callContracts: [], payloadShapes: [], testReferences: [] });
  const entry = grouped.get(call.name);
  entry.callSites.push({ file: call.file, line: call.line, via: call.via });
  entry.callContracts.push({ file: call.file, line: call.line, variants: call.payloadVariants });
  for (const shape of call.payloadVariants) {
    if (!entry.payloadShapes.some((candidate) => JSON.stringify(candidate) === JSON.stringify(shape))) entry.payloadShapes.push(shape);
  }
}
for (const entry of grouped.values()) {
  entry.testReferences = [...testText.entries()].filter(([, text]) => text.includes(entry.name)).map(([file]) => file);
}

const inventory = [...grouped.values()].sort((a, b) => a.name.localeCompare(b.name));
const report = { generatedFrom: "runtime TypeScript AST", filesScanned: files.length, uniqueCount: inventory.length, callCount: calls.length, unresolved, inventory };
const serialized = `${JSON.stringify(report, null, 2)}\n`;
if (outputPath) fs.writeFileSync(outputPath, serialized);
process.stdout.write(serialized);
