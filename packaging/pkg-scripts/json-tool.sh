#!/bin/bash
# JSON reader/editor for supported macOS releases. The hosted macOS 15 plutil
# rejects JSON input, so customer-side scripts use the system JavaScriptCore
# parser through osascript.
set -euo pipefail

ACTION="${1:-}"
FILE="${2:-}"
KEY_PATH="${3:-}"
JSON_VALUE="${4:-}"

case "$ACTION" in
  validate|dump) ;;
  get|type|has|remove) [ -n "$KEY_PATH" ] || ACTION="" ;;
  set) [ -n "$KEY_PATH" ] && [ -n "$JSON_VALUE" ] || ACTION="" ;;
  *) ACTION="" ;;
esac
[ -n "$ACTION" ] && [ -n "$FILE" ] || {
  echo "json-tool: usage: json-tool.sh validate|dump|get|type|has|remove|set file [key.path] [json-value]" >&2
  exit 64
}
[ ! -L "$FILE" ] && [ -f "$FILE" ] \
  && [ "$(/usr/bin/stat -f '%l' "$FILE" 2>/dev/null || printf 0)" = "1" ] || {
  printf 'json-tool: file configured=regular-nonsymlink-links-1 observed=unsafe path=%q\n' \
    "$FILE" >&2
  exit 66
}

set +e
RESULT=$(/usr/bin/osascript -l JavaScript - \
  "$ACTION" "$FILE" "$KEY_PATH" "$JSON_VALUE" 2>/dev/null <<'JXA'
ObjC.import("Foundation");

function own(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function parts(keyPath) {
    const result = keyPath.split(".");
    if (result.length === 0 || result.some(function (part) { return part.length === 0; })) {
        throw new Error("invalid key path");
    }
    return result;
}

function readObject(path) {
    const value = $.NSString.stringWithContentsOfFileEncodingError(
        path, $.NSUTF8StringEncoding, null);
    if (!value) {
        throw new Error("read failed");
    }
    const parsed = JSON.parse(ObjC.unwrap(value));
    if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object") {
        throw new Error("root is not an object");
    }
    return parsed;
}

function lookup(root, keyPath) {
    const path = parts(keyPath);
    let value = root;
    for (let index = 0; index < path.length; index += 1) {
        if (value === null || Array.isArray(value) || typeof value !== "object"
                || !own(value, path[index])) {
            return { found: false };
        }
        value = value[path[index]];
    }
    return { found: true, value: value };
}

function parentFor(root, keyPath) {
    const path = parts(keyPath);
    const key = path.pop();
    let parent = root;
    for (let index = 0; index < path.length; index += 1) {
        if (parent === null || Array.isArray(parent) || typeof parent !== "object"
                || !own(parent, path[index])) {
            throw new Error("missing parent");
        }
        parent = parent[path[index]];
    }
    if (parent === null || Array.isArray(parent) || typeof parent !== "object") {
        throw new Error("parent is not an object");
    }
    return { parent: parent, key: key };
}

function typeName(value) {
    if (value === null) { return "null"; }
    if (Array.isArray(value)) { return "array"; }
    if (typeof value === "object") { return "dictionary"; }
    return typeof value;
}

function rawValue(value) {
    if (typeof value === "string") { return value; }
    return JSON.stringify(value);
}

function writeObject(path, object) {
    const text = $(JSON.stringify(object) + "\n");
    const written = text.writeToFileAtomicallyEncodingError(
        path, false, $.NSUTF8StringEncoding, null);
    if (!written) {
        throw new Error("write failed");
    }
}

function run(arguments) {
    const action = arguments[0];
    const path = arguments[1];
    const keyPath = arguments[2];
    const encodedValue = arguments[3];
    const root = readObject(path);

    if (action === "validate") { return; }
    if (action === "dump") { return JSON.stringify(root); }

    const found = lookup(root, keyPath);
    if (action === "has") { return found.found ? "true" : "false"; }
    if (action === "type") { return found.found ? typeName(found.value) : "missing"; }
    if (action === "get") {
        if (!found.found) { throw new Error("missing key"); }
        return rawValue(found.value);
    }

    const target = parentFor(root, keyPath);
    if (!own(target.parent, target.key)) { throw new Error("missing key"); }
    if (action === "remove") {
        delete target.parent[target.key];
    } else if (action === "set") {
        target.parent[target.key] = JSON.parse(encodedValue);
    } else {
        throw new Error("unknown action");
    }
    writeObject(path, root);
}
JXA
)
STATUS=$?
set -e

[ "$STATUS" -eq 0 ] || {
  printf 'json-tool: action=%s configured=valid-object-and-key observed=parser-or-operation-failure exit=%s path=%q\n' \
    "$ACTION" "$STATUS" "$FILE" >&2
  exit 1
}
[ -z "$RESULT" ] || printf '%s\n' "$RESULT"
