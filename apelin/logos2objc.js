// Turns a Logos (.xm) file into plain Objective-C for the on-device toolchain, which has no
// Perl and therefore no logos.pl. It handles what this project uses: %group, %hook, %end,
// %ctor, %init, %orig and %c. Anything else is copied through unchanged.
//
// Run through `icli probe`, with @@SRC@@ and @@DST@@ replaced by absolute paths.

var SRC = '@@SRC@@';
var DST = '@@DST@@';

function text(path) {
  return String(fs.read(path));
}

var src = text(SRC);
var lines = src.split('\n');

var out = [];
var uid = 0;
var groupStack = [];
var topInstalls = [];
var hook = null;
var method = null;
var inCtor = false;
var ctorDepth = 0;
var ctorCount = 0;
var classDecls = [];
var seenClasses = {};

out.push('// Generated from ' + SRC.split('/').pop() + ' by apelin/logos2objc.js — do not edit.');
out.push('#import <objc/runtime.h>');
out.push('extern void MSHookMessageEx(Class cls, SEL name, IMP imp, IMP *result);');
out.push('');

function installs() {
  if (groupStack.length) return groupStack[groupStack.length - 1].installs;
  return topInstalls;
}

// Brace/comment/string aware scan of one line.
function scan(line, state) {
  var res = {open: 0, close: 0, text: line, orig: [], c: []};
  state.lineComment = false;
  var i = 0;
  var kept = '';
  while (i < line.length) {
    if (state.blockComment) {
      var e = line.indexOf('*/', i);
      if (e < 0) { kept += line.slice(i); i = line.length; break; }
      kept += line.slice(i, e + 2); i = e + 2; state.blockComment = false; continue;
    }
    var ch = line.charAt(i);
    if (state.lineComment) { kept += line.slice(i); break; }
    if (state.inString) {
      if (ch === '\\') { kept += line.slice(i, i + 2); i += 2; continue; }
      if (ch === '"') state.inString = false;
      kept += ch; i++; continue;
    }
    if (state.inChar) {
      if (ch === '\\') { kept += line.slice(i, i + 2); i += 2; continue; }
      if (ch === "'") state.inChar = false;
      kept += ch; i++; continue;
    }
    if (ch === '"') { state.inString = true; kept += ch; i++; continue; }
    if (ch === "'") { state.inChar = true; kept += ch; i++; continue; }
    if (ch === '/' && line.charAt(i + 1) === '/') { state.lineComment = true; kept += line.slice(i); break; }
    if (ch === '/' && line.charAt(i + 1) === '*') { state.blockComment = true; kept += '/*'; i += 2; continue; }
    if (ch === '{') { res.open++; kept += ch; i++; continue; }
    if (ch === '}') { res.close++; kept += ch; i++; continue; }
    if (ch === '%') {
      if (line.substr(i, 5) === '%orig') { res.orig.push(i); i += 5; kept += '%orig'; continue; }
      if (line.substr(i, 2) === '%c') { res.c.push(i); }
    }
    kept += ch; i++;
  }
  res.text = kept;
  return res;
}

function newState() {
  return {inString: false, inChar: false, lineComment: false, blockComment: false};
}

function balance(text) {
  var d = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.charAt(i) === '(') d++;
    else if (text.charAt(i) === ')') d--;
  }
  return d;
}

// Splits `- (CGRect)frame` / `- (void)setFoo:(id)foo bar:(BOOL)bar` into its parts.
function parseMethod(line) {
  var s = line.replace(/\s+$/, '').replace(/\s*\{$/, '');
  var kind = s.charAt(0);
  if (kind !== '-' && kind !== '+') return null;
  var i = 1;
  while (s.charAt(i) === ' ') i++;
  if (s.charAt(i) !== '(') return null;
  var d = 0, j = i;
  for (; j < s.length; j++) {
    var c = s.charAt(j);
    if (c === '(') d++;
    else if (c === ')') { d--; if (!d) break; }
  }
  if (d !== 0) return null;
  var ret = s.slice(i + 1, j).trim();
  var rest = s.slice(j + 1).trim();
  var params = [], selector = '';
  var guard = 0;
  while (guard++ < 24) {
    var colon = -1, depth = 0;
    for (var k = 0; k < rest.length; k++) {
      var ch = rest.charAt(k);
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
      else if (ch === ':' && depth === 0) { colon = k; break; }
    }
    if (colon < 0) break;
    var label = rest.slice(0, colon).trim();
    if (label.indexOf(' ') >= 0 || label.indexOf('(') >= 0) return null;
    selector += label + ':';
    var m = colon + 1;
    while (rest.charAt(m) === ' ') m++;
    if (rest.charAt(m) !== '(') return null;
    var dd = 0, e = m;
    for (; e < rest.length; e++) {
      var c2 = rest.charAt(e);
      if (c2 === '(') dd++;
      else if (c2 === ')') { dd--; if (!dd) break; }
    }
    if (dd !== 0) return null;
    var type = rest.slice(m + 1, e).trim();
    var after = rest.slice(e + 1);
    var match = after.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)/);
    var name = match ? match[1] : ('arg' + params.length);
    params.push({type: type, name: name});
    rest = match ? after.slice(match[0].length).trim() : after.trim();
  }
  if (!selector.length) {
    var unary = rest.match(/^([A-Za-z_][A-Za-z0-9_]*)/);
    if (!unary) return null;
    selector = unary[1];
  }
  return {kind: kind, ret: ret, params: params, selector: selector};
}

function rewrite(line, info) {
  var state = newState();
  var res = '';
  var i = 0;
  while (i < line.length) {
    var idx = line.indexOf('%', i);
    if (idx < 0) { res += line.slice(i); break; }
    var before = scanPrefix(line.slice(0, idx));
    if (!before) { res += line.slice(i, idx + 1); i = idx + 1; continue; }
    res += line.slice(i, idx);
    if (line.substr(idx, 5) === '%orig') {
      var j = idx + 5;
      while (line.charAt(j) === ' ' || line.charAt(j) === '\t') j++;
      if (line.charAt(j) === '(') {
        var d = 0, k = j;
        for (; k < line.length; k++) {
          if (line.charAt(k) === '(') d++;
          else if (line.charAt(k) === ')') { d--; if (!d) break; }
        }
        var args = line.slice(j + 1, k).trim();
        res += 'LSR_orig_' + info.id + '(self, _cmd' + (args.length ? ', ' + args : '') + ')';
        i = k + 1;
      } else {
        var names = info.params.map(function (p) { return p.name; });
        res += 'LSR_orig_' + info.id + '(self, _cmd' + (names.length ? ', ' + names.join(', ') : '') + ')';
        i = idx + 5;
      }
      continue;
    }
    if (line.substr(idx, 2) === '%c') {
      var m = line.slice(idx).match(/^%c\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/);
      if (m) {
        res += '(Class)objc_getClass("' + m[1] + '")';
        i = idx + m[0].length;
        continue;
      }
    }
    res += '%';
    i = idx + 1;
  }
  return res;
}

// True when the position sits in code (not in a string or a comment).
function scanPrefix(prefix) {
  var state = newState();
  for (var i = 0; i < prefix.length; i++) {
    var ch = prefix.charAt(i);
    if (state.blockComment) {
      if (ch === '*' && prefix.charAt(i + 1) === '/') { state.blockComment = false; i++; }
      continue;
    }
    if (state.lineComment) return false;
    if (state.inString) {
      if (ch === '\\') { i++; continue; }
      if (ch === '"') state.inString = false;
      continue;
    }
    if (state.inChar) {
      if (ch === '\\') { i++; continue; }
      if (ch === "'") state.inChar = false;
      continue;
    }
    if (ch === '"') { state.inString = true; continue; }
    if (ch === "'") { state.inChar = true; continue; }
    if (ch === '/' && prefix.charAt(i + 1) === '/') return false;
    if (ch === '/' && prefix.charAt(i + 1) === '*') { state.blockComment = true; i++; continue; }
  }
  return true;
}

var state = newState();

for (var n = 0; n < lines.length; n++) {
  var line = lines[n];
  var trimmed = line.replace(/\s+$/, '');
  var lead = trimmed.replace(/^\s+/, '');

  if (method) {
    var body = rewrite(line, method.info);
    out.push(body);
    var sc = scan(body, state);
    method.depth += sc.open - sc.close;
    if (method.depth <= 0) {
      out.push('');
      emitInstaller(method.hook, method.parsed, method.info);
      method = null;
    }
    continue;
  }

  if (inCtor) {
    var ctorLine = line.replace(/%init\(\s*([A-Za-z_][A-Za-z0-9_]*)[^)]*\)/g, 'LSRGroup_$1()');
    out.push(ctorLine);
    var csc = scan(ctorLine, state);
    ctorDepth += csc.open - csc.close;
    if (ctorDepth <= 0) {
      inCtor = false;
      out.push('');
    }
    continue;
  }

  if (hook) {
    if (lead.indexOf('%end') === 0) {
      var target = installs();
      for (var hi = 0; hi < hook.installs.length; hi++) target.push(hook.installs[hi]);
      hook = null;
      continue;
    }
    if (/^[+-]\s*\(/.test(lead)) {
      var parsed = parseMethod(lead);
      if (parsed) {
        var info = {id: ++uid, params: parsed.params};
        var ret = parsed.ret === 'instancetype' ? 'id' : parsed.ret;
        var paramDecls = parsed.params.map(function (p) {
          var block = p.type.match(/^(.*?)\(\s*\^\s*\)\s*(\(.*\))$/);
          if (block) return ', ' + block[1].trim() + '(^' + p.name + ')' + block[2];
          return ', ' + p.type + ' ' + p.name;
        }).join('');
        var paramTypes = parsed.params.map(function (p) { return ', ' + p.type; }).join('');
        out.push('// ' + hook.cls + ' ' + parsed.selector);
        out.push('static ' + ret + ' (*LSR_orig_' + info.id + ')(id, SEL' + paramTypes + ');');
        out.push('static ' + ret + ' LSR_hook_' + info.id + '(' + hook.cls + ' *self, SEL _cmd' + paramDecls + ') {');
        method = {info: info, depth: 1, hook: hook, parsed: parsed};
        // Anything after the opening brace belongs to the body.
        var afterBrace = lead.slice(lead.indexOf('{') + 1).replace(/\s+$/, '');
        if (afterBrace.length) {
          out.push(rewrite(afterBrace, info));
          var inline = scan(afterBrace, state);
          method.depth += inline.open - inline.close;
          if (method.depth <= 0) {
            out.push('}');
            out.push('');
            emitInstaller(hook, parsed, info);
            method = null;
          }
        }
        continue;
      }
    }
    out.push(line);
    continue;
  }

  if (lead.indexOf('%group ') === 0) {
    var name = lead.slice(7).trim();
    groupStack.push({name: name, installs: []});
    continue;
  }
  if (lead.indexOf('%end') === 0 && groupStack.length) {
    var group = groupStack.pop();
    out.push('static void LSRGroup_' + group.name + '(void) {');
    for (var g = 0; g < group.installs.length; g++) out.push('    ' + group.installs[g] + '();');
    if (!group.installs.length) out.push('    // no hooks');
    out.push('}');
    out.push('');
    continue;
  }
  if (lead.indexOf('%hook ') === 0) {
    var hooked = lead.slice(6).trim();
    if (!seenClasses[hooked]) {
      // Logos forward-declares the class; without it `ClassName *self` is an unknown type.
      seenClasses[hooked] = true;
      classDecls.push('@class ' + hooked + ';');
    }
    hook = {cls: hooked, installs: []};
    continue;
  }
  if (lead.indexOf('%ctor') === 0) {
    ctorCount++;
    out.push('__attribute__((constructor)) static void LSRCtor' + ctorCount + '(void) {');
    inCtor = true;
    var ctorOpen = scan(line, state);
    ctorDepth = ctorOpen.open - ctorOpen.close;
    continue;
  }

  out.push(line);
}

if (topInstalls.length) {
  out.push('__attribute__((constructor)) static void LSRCtorTop(void) {');
  for (var t = 0; t < topInstalls.length; t++) out.push('    ' + topInstalls[t] + '();');
  out.push('}');
  out.push('');
}

// Closes a method: the hook function is done, so install it.
function emitInstaller(hookRef, parsed, info) {
  out.push('static void LSR_install_' + info.id + '(void) {');
  out.push('    Class cls = objc_getClass("' + hookRef.cls + '");');
  out.push('    if (!cls) return;');
  out.push('    MSHookMessageEx(' + (parsed.kind === '+' ? 'object_getClass((id)cls)' : 'cls') +
    ', @selector(' + parsed.selector + '), (IMP)&LSR_hook_' + info.id + ', (IMP *)&LSR_orig_' + info.id + ');');
  out.push('}');
  out.push('');
  hookRef.installs.push('LSR_install_' + info.id);
}

var headerLines = out.splice(0, 4);
var body = headerLines;
if (classDecls.length) body = body.concat([''], classDecls);
body = body.concat(out);

fs.write(DST, body.join('\n') + '\n');
print('wrote ' + DST + ': ' + body.length + ' lines, ' + uid + ' methods');
