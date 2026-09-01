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

function staticStrings(file, node) {
  node = resolveInitializer(file, node);
  if (node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node))) return [node.text];
  if (node && ts.isConditionalExpression(node)) {
    return [...new Set([...staticStrings(file, node.whenTrue), ...staticStrings(file, node.whenFalse)])];
  }
  return [];
}

function payloadVariants(file, node) {
  if (!node) return [{ keys: [], dynamic: false }];
  node = resolveInitializer(file, node);
  if (node && ts.isConditionalExpression(node)) {
    return [...payloadVariants(file, node.whenTrue), ...payloadVariants(file, node.whenFalse)];
  }
  if (!node || !ts.isObjectLiteralExpression(node)) return [{ keys: [], dynamic: true }];
  let variants = [{ keys: [], dynamic: false }];
  for (const property of node.properties) {
    if (ts.isSpreadAssignment(property)) {
      const spreadVariants = payloadVariants(file, property.expression);
      variants = variants.flatMap((base) => spreadVariants.map((spread) => ({
        keys: [...new Set([...base.keys, ...spread.keys])].sort(),
        dynamic: base.dynamic || spread.dynamic,
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
  function add(name, node, payloads, via) {
    const position = source.getLineAndCharacterOfPosition(node.getStart(source));
    calls.push({ name, file: relative, line: position.line + 1, payloadVariants: payloads, via });
  }
  function visit(node) {
    if (ts.isCallExpression(node)) {
      if (ts.isPropertyAccessExpression(node.expression) && node.expression.name.text === "rpc") {
        const names = staticStrings(file, node.arguments[0]);
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
        const names = staticStrings(file, node.arguments[wrapper.rpcNameIndex]);
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
