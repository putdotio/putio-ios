#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import process from "node:process";

export class Unreadable extends Error {}

const PKCS7_ERROR = "Could not parse the PKCS7: no start line (Expecting: PKCS7)";

const divmod = (a: number, b: number): [number, number] => {
  const q = Math.floor(a / b);
  return [q, a - q * b];
};

const gcd = (a: bigint, b: bigint): bigint => (b === 0n ? a : gcd(b, a % b));

const pad = (n: number, width = 2) => (n < 0 ? `-${String(-n).padStart(width, "0")}` : String(n).padStart(width, "0"));

const LEAP_MONTH_DAYS = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
const COMMON_MONTH_DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

const monthDays = (year: number, mon: number): number | undefined => {
  const days = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0 ? LEAP_MONTH_DAYS : COMMON_MONTH_DAYS;
  return days.at(mon - 1);
};

const applyOffset = (fields: [number, number, number, number, number, number], offset: number) => {
  let [year, mon, day, hour, min, sec] = fields;
  let off = offset;
  let o: number;
  if (off < 0) {
    off = -off;
    [off, o] = divmod(off, 60);
    if (o !== 0) { sec += o; [o, sec] = divmod(sec, 60); off += o; }
    [off, o] = divmod(off, 60);
    if (o !== 0) { min += o; [o, min] = divmod(min, 60); off += o; }
    [off, o] = divmod(off, 24);
    if (o !== 0) { hour += o; [o, hour] = divmod(hour, 24); off += o; }
    if (off !== 0) {
      day += off;
      const days = monthDays(year, mon);
      if (days !== undefined && days < day) {
        mon += 1;
        if (12 < mon) { mon = 1; year += 1; }
        day = 1;
      }
    }
  } else if (0 < off) {
    [off, o] = divmod(off, 60);
    if (o !== 0) { sec -= o; [o, sec] = divmod(sec, 60); off -= o; }
    [off, o] = divmod(off, 60);
    if (o !== 0) { min -= o; [o, min] = divmod(min, 60); off -= o; }
    [off, o] = divmod(off, 24);
    if (o !== 0) { hour -= o; [o, hour] = divmod(hour, 24); off -= o; }
    if (off !== 0) {
      day -= off;
      if (day < 1) {
        mon -= 1;
        if (mon < 1) { year -= 1; mon = 12; }
        day = monthDays(year, mon) ?? day;
      }
    }
  }
  return [year, mon, day, hour, min, sec] as const;
};

const zoneOffset = (zone: string): number | undefined => {
  const upper = zone.toUpperCase();
  const full = /^([+-])(\d\d):?(\d\d)$/.exec(upper);
  if (full) return (full[1] === "-" ? -1 : 1) * ((Number(full[2]) * 60 + Number(full[3])) * 60);
  if (/^[+-]\d\d$/.test(upper)) return Number(upper) * 3600;
  if (upper === "Z" || upper === "UTC" || upper === "UT" || upper === "GMT") return 0;
  return undefined;
};

const FOUR_CENTURIES_MS = 146097 * 86400000;

export class RubyTime {
  readonly epochMs: number;
  readonly subsecNum: bigint;
  readonly subsecDen: bigint;
  readonly utcOffset: number | "UTC";

  constructor(epochMs: number, subsecNum: bigint, subsecDen: bigint, utcOffset: number | "UTC") {
    this.epochMs = epochMs;
    this.subsecNum = subsecNum;
    this.subsecDen = subsecDen;
    this.utcOffset = utcOffset;
  }

  static iso8601(text: string): RubyTime {
    const match = /^\s*(-?\d+)-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d(?::?\d\d)?)?\s*$/i.exec(text);
    if (!match) throw new Unreadable(`invalid xmlschema format: ${inspectString(text)}`);
    const [, y, mo, d, h, mi, s, fraction, zone] = match;
    let fields: [number, number, number, number, number, number] = [Number(y), Number(mo), Number(d), Number(h), Number(mi), Number(s)];
    let subsecNum = 0n;
    let subsecDen = 1n;
    if (fraction) {
      subsecNum = BigInt(fraction.slice(1));
      subsecDen = 10n ** BigInt(fraction.length - 1);
      const divisor = gcd(subsecNum, subsecDen);
      if (subsecNum !== 0n) { subsecNum /= divisor; subsecDen /= divisor; } else subsecDen = 1n;
    }
    let offset: number | undefined;
    if (zone) {
      offset = zoneOffset(zone) ?? 0;
      fields = [...applyOffset(fields, offset)];
    }
    const [year, mon, day, hour, min, sec] = fields;
    if (mon < 1 || mon > 12) throw new Unreadable("mon out of range");
    if (day < 1) throw new Unreadable("mday out of range");
    if (day > 31) throw new Unreadable("argument out of range");
    if (hour > 24) throw new Unreadable("hour out of range");
    if (min > 59 || (hour === 24 && min !== 0)) throw new Unreadable("min out of range");
    if (sec > 60 || (hour === 24 && sec !== 0)) throw new Unreadable("sec out of range");
    const shifted = year >= 0 && year < 100 ? year + 400 : year;
    const shift = shifted === year ? 0 : FOUR_CENTURIES_MS;
    if (zone === undefined) {
      const local = new Date(shifted, mon - 1, day, hour, min, sec).getTime() - shift;
      return new RubyTime(local, subsecNum, subsecDen, -new Date(local).getTimezoneOffset() * 60);
    }
    const epochMs = Date.UTC(shifted, mon - 1, day, hour, min, sec) - shift;
    if (/^(?:-00:00|-0000|-00|UTC|Z|UT)$/i.test(zone)) return new RubyTime(epochMs, subsecNum, subsecDen, "UTC");
    const fixed = offset ?? 0;
    if (Math.abs(fixed) >= 86400) throw new Unreadable("utc_offset out of range");
    return new RubyTime(epochMs, subsecNum, subsecDen, fixed);
  }

  compare(other: RubyTime): number {
    if (this.epochMs !== other.epochMs) return this.epochMs < other.epochMs ? -1 : 1;
    const left = this.subsecNum * other.subsecDen;
    const right = other.subsecNum * this.subsecDen;
    return left === right ? 0 : left < right ? -1 : 1;
  }

  isAfterNow(): boolean {
    return this.epochMs + (Number(this.subsecNum) * 1000) / Number(this.subsecDen) > Date.now();
  }

  private local(): string {
    const shift = this.utcOffset === "UTC" ? 0 : this.utcOffset * 1000;
    const date = new Date(this.epochMs + shift);
    const year = date.getUTCFullYear();
    return `${pad(year, 4)}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}`;
  }

  private zone(): string {
    if (this.utcOffset === "UTC") return "UTC";
    const sign = this.utcOffset < 0 ? "-" : "+";
    const minutes = Math.floor(Math.abs(this.utcOffset) / 60);
    return `${sign}${pad(Math.floor(minutes / 60))}${pad(minutes % 60)}`;
  }

  toS(): string {
    return `${this.local()} ${this.zone()}`;
  }

  inspect(): string {
    let subsec = "";
    if (this.subsecNum !== 0n) {
      const nanos = this.subsecNum * 1_000_000_000n;
      subsec = nanos % this.subsecDen === 0n
        ? `.${String(nanos / this.subsecDen).padStart(9, "0").replace(/0+$/, "")}`
        : ` ${this.subsecNum}/${this.subsecDen}`;
    }
    return `${this.local()}${subsec} ${this.zone()}`;
  }
}

export type PlistValue = string | boolean | bigint | Buffer | RubyTime | PlistValue[] | PlistDict;
export type PlistDict = Map<string, PlistValue>;

type XmlText = { text: string };
type XmlElement = { name: string; children: (XmlElement | XmlText)[] };

const isElement = (node: XmlElement | XmlText): node is XmlElement => "name" in node;

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

const unescape = (text: string) =>
  text.replace(/&(#x[0-9A-Fa-f]+|#\d+|[A-Za-z_][\w.-]*);/g, (whole, name: string) => {
    if (name.startsWith("#x")) return String.fromCodePoint(Number.parseInt(name.slice(2), 16));
    if (name.startsWith("#")) return String.fromCodePoint(Number.parseInt(name.slice(1), 10));
    return ENTITIES[name] ?? whole;
  });

export const parseXml = (source: string): XmlElement | undefined => {
  const xml = source.replace(/^﻿/, "").replace(/\r\n?/g, "\n");
  const stack: XmlElement[] = [];
  let root: XmlElement | undefined;
  let pos = 0;
  const fail = (message: string): never => { throw new Unreadable(`Malformed XML: ${message}`); };
  const skipTo = (marker: string) => {
    const end = xml.indexOf(marker, pos);
    if (end < 0) fail(`missing ${marker}`);
    pos = end + marker.length;
  };
  while (pos < xml.length) {
    if (xml.startsWith("<?", pos)) skipTo("?>");
    else if (xml.startsWith("<!--", pos)) skipTo("-->");
    else if (xml.startsWith("<![CDATA[", pos)) {
      const end = xml.indexOf("]]>", pos);
      if (end < 0) fail("unclosed CDATA");
      const parent = stack.at(-1) ?? fail("CDATA outside the root element");
      parent.children.push({ text: xml.slice(pos + 9, end) });
      pos = end + 3;
    } else if (xml.startsWith("<!DOCTYPE", pos)) {
      if (root || stack.length) fail("DOCTYPE after the root element");
      const declaration = /^<!DOCTYPE(?:[^[>"']|"[^"]*"|'[^']*')*(?:\[[\s\S]*?\]\s*)?>/.exec(xml.slice(pos)) ?? fail("bad DOCTYPE");
      pos += declaration[0].length;
    } else if (xml.startsWith("</", pos)) {
      const close = /^<\/([^\s>/]+)\s*>/.exec(xml.slice(pos)) ?? fail("bad end tag");
      const open = stack.pop();
      if (open?.name !== close[1]) fail(`missing end tag for ${open?.name ?? "nothing"} (got ${close[1]})`);
      pos += close[0].length;
    } else if (xml[pos] === "<") {
      const tag = /^<([^\s>/!?]+)(?:\s+[^\s=>/]+\s*=\s*(?:"[^"<]*"|'[^'<]*'))*\s*(\/?)>/.exec(xml.slice(pos)) ?? fail("bad start tag");
      const name = tag[1] ?? fail("bad start tag");
      const element: XmlElement = { name, children: [] };
      const parent = stack.at(-1);
      if (parent) parent.children.push(element);
      else if (root) fail("a second root element");
      else root = element;
      if (tag[2] !== "/") stack.push(element);
      pos += tag[0].length;
    } else {
      const end = xml.indexOf("<", pos);
      const raw = xml.slice(pos, end < 0 ? xml.length : end);
      if (/&(?!#x[0-9A-Fa-f]+;|#\d+;|[A-Za-z_][\w.-]*;)/.test(raw)) fail("bad text");
      const parent = stack.at(-1);
      if (parent) parent.children.push({ text: unescape(raw) });
      else if (raw.trim() !== "") fail(`Content at the start of the document (got '${raw.trim()}')`);
      pos += raw.length;
    }
  }
  if (stack.length) fail(`missing end tag for ${stack.at(-1)?.name}`);
  return root;
};

const textOf = (node: XmlElement): string => {
  const first = node.children.find((child) => !isElement(child));
  return first && !isElement(first) ? first.text : "";
};

const elementsOf = (node: XmlElement) => node.children.filter(isElement);

export const rubyInteger = (text: string): bigint => {
  const match = /^\s*([+-]?)(?:0x([0-9a-f]+(?:_[0-9a-f]+)*)|0b([01]+(?:_[01]+)*)|0o?((?:_?[0-7]+)*)|0d(\d+(?:_\d+)*)|([1-9]\d*(?:_\d+)*))\s*$/i.exec(text);
  if (!match) throw new Unreadable(`invalid value for Integer(): ${inspectString(text)}`);
  const [, sign, hex, bin, oct, dec, plain] = match;
  const digits = (value: string) => value.replaceAll("_", "");
  const magnitude = hex !== undefined ? BigInt(`0x${digits(hex)}`)
    : bin !== undefined ? BigInt(`0b${digits(bin)}`)
    : oct !== undefined ? (digits(oct) === "" ? 0n : BigInt(`0o${digits(oct)}`))
    : BigInt(digits(dec ?? plain ?? "0"));
  return sign === "-" ? -magnitude : magnitude;
};

export const plistValue = (node: XmlElement | undefined): PlistValue => {
  if (!node) throw new TypeError("undefined method 'name' for nil");
  switch (node.name) {
    case "dict": {
      const dict: PlistDict = new Map();
      const children = elementsOf(node);
      for (let i = 0; i < children.length; i += 2) {
        const key = children[i];
        if (!key) break;
        dict.set(textOf(key), plistValue(children[i + 1]));
      }
      return dict;
    }
    case "array": return elementsOf(node).map(plistValue);
    case "data": return Buffer.from(textOf(node), "base64");
    case "date": return RubyTime.iso8601(textOf(node));
    case "true": return true;
    case "false": return false;
    case "integer": return rubyInteger(textOf(node));
    default: return textOf(node);
  }
};

type Tlv = { cls: number; constructed: boolean; tag: number; start: number; contentStart: number; contentEnd: number; next: number };

const readTlv = (buf: Buffer, start: number, limit: number): Tlv => {
  let pos = start;
  const byte = () => {
    if (pos >= limit) throw new Unreadable(PKCS7_ERROR);
    return buf[pos++] ?? 0;
  };
  const first = byte();
  let tag = first & 0x1f;
  if (tag === 0x1f) {
    tag = 0;
    let part: number;
    do { part = byte(); tag = tag * 128 + (part & 0x7f); } while (part & 0x80);
  }
  const constructed = (first & 0x20) !== 0;
  const lengthByte = byte();
  if (lengthByte === 0x80) {
    if (!constructed) throw new Unreadable(PKCS7_ERROR);
    const contentStart = pos;
    let cursor = contentStart;
    for (;;) {
      if (cursor + 2 > limit) throw new Unreadable(PKCS7_ERROR);
      if (buf[cursor] === 0 && buf[cursor + 1] === 0) break;
      cursor = readTlv(buf, cursor, limit).next;
    }
    return { cls: first >> 6, constructed, tag, start, contentStart, contentEnd: cursor, next: cursor + 2 };
  }
  let length = lengthByte;
  if (lengthByte & 0x80) {
    const count = lengthByte & 0x7f;
    if (count > 6) throw new Unreadable(PKCS7_ERROR);
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + byte();
  }
  if (pos + length > limit) throw new Unreadable(PKCS7_ERROR);
  return { cls: first >> 6, constructed, tag, start, contentStart: pos, contentEnd: pos + length, next: pos + length };
};

const childrenOf = (buf: Buffer, node: Tlv): Tlv[] => {
  if (!node.constructed) throw new Unreadable(PKCS7_ERROR);
  const children: Tlv[] = [];
  for (let pos = node.contentStart; pos < node.contentEnd;) {
    const child = readTlv(buf, pos, node.contentEnd);
    children.push(child);
    pos = child.next;
  }
  return children;
};

const is = (node: Tlv | undefined, cls: number, tag: number, constructed?: boolean): node is Tlv =>
  node !== undefined && node.cls === cls && node.tag === tag && (constructed === undefined || node.constructed === constructed);

const SEQUENCE = 16;
const SET = 17;
const OID_TAG = 6;
const OCTET_STRING = 4;
const INTEGER = 2;
const SIGNED_DATA = Buffer.from("2a864886f70d010702", "hex");

const expect = (node: Tlv | undefined, cls: number, tag: number, constructed?: boolean): Tlv => {
  if (!is(node, cls, tag, constructed)) throw new Unreadable(PKCS7_ERROR);
  return node;
};

const contentOf = (buf: Buffer, node: Tlv) => buf.subarray(node.contentStart, node.contentEnd);
const encodingOf = (buf: Buffer, node: Tlv) => buf.subarray(node.start, node.next);

const octets = (buf: Buffer, node: Tlv): Buffer =>
  node.constructed ? Buffer.concat(childrenOf(buf, node).map((child) => octets(buf, expect(child, 0, OCTET_STRING)))) : contentOf(buf, node);

export const pkcs7Payload = (der: Buffer): Buffer => {
  if (der.length === 0) throw new Unreadable(PKCS7_ERROR);
  const info = childrenOf(der, expect(readTlv(der, 0, der.length), 0, SEQUENCE, true));
  const type = expect(info[0], 0, OID_TAG, false);
  if (!contentOf(der, type).equals(SIGNED_DATA)) return Buffer.alloc(0);
  if (!info[1]) return Buffer.alloc(0);
  const [signed] = childrenOf(der, expect(info[1], 2, 0, true));
  const fields = childrenOf(der, expect(signed, 0, SEQUENCE, true));
  expect(fields[0], 0, INTEGER, false);
  expect(fields[1], 0, SET, true);
  const encapsulated = childrenOf(der, expect(fields[2], 0, SEQUENCE, true));
  expect(encapsulated[0], 0, OID_TAG, false);
  let index = 3;
  const certificates = is(fields[index], 2, 0, true) ? childrenOf(der, fields[index++] as Tlv) : [];
  if (is(fields[index], 2, 1, true)) index++;
  const signers = childrenOf(der, expect(fields[index], 0, SET, true));
  const identities = certificates.map((certificate) => {
    const tbs = childrenOf(der, expect(childrenOf(der, expect(certificate, 0, SEQUENCE, true))[0], 0, SEQUENCE, true));
    const offset = is(tbs[0], 2, 0, true) ? 1 : 0;
    return { serial: contentOf(der, expect(tbs[offset], 0, INTEGER, false)), issuer: encodingOf(der, expect(tbs[offset + 2], 0, SEQUENCE, true)) };
  });
  const signerFound = signers.map((signer) => {
    const signerFields = childrenOf(der, expect(signer, 0, SEQUENCE, true));
    const [issuer, serial] = childrenOf(der, expect(signerFields[1], 0, SEQUENCE, true));
    const issuerBytes = encodingOf(der, expect(issuer, 0, SEQUENCE, true));
    const serialBytes = contentOf(der, expect(serial, 0, INTEGER, false));
    return identities.some((identity) => identity.issuer.equals(issuerBytes) && identity.serial.equals(serialBytes));
  });
  if (signers.length === 0 || signerFound.includes(false)) return Buffer.alloc(0);
  const explicit = encapsulated[1];
  if (!is(explicit, 2, 0, true)) return Buffer.alloc(0);
  const [content] = childrenOf(der, explicit);
  return is(content, 0, OCTET_STRING) ? octets(der, content) : Buffer.alloc(0);
};

export const readProfile = (der: Buffer): PlistDict => {
  const root = parseXml(new TextDecoder().decode(pkcs7Payload(der)));
  const first = root ? elementsOf(root)[0] : undefined;
  const profile = first?.name === "dict" ? plistValue(first) : undefined;
  if (!(profile instanceof Map)) throw new Unreadable("no property list");
  return profile;
};

const inspectString = (text: string) => JSON.stringify(text);

export const rubyToS = (value: unknown): string => {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value;
  if (typeof value === "bigint" || typeof value === "boolean") return String(value);
  if (typeof value === "number") return String(value);
  if (Buffer.isBuffer(value)) return value.toString("utf8");
  if (value instanceof RubyTime) return value.toS();
  return rubyInspect(value);
};

const rubyInspect = (value: unknown): string => {
  if (value === undefined || value === null) return "nil";
  if (typeof value === "string") return inspectString(value);
  if (Buffer.isBuffer(value)) return inspectString(value.toString("latin1"));
  if (value instanceof RubyTime) return value.inspect();
  if (Array.isArray(value)) return `[${value.map(rubyInspect).join(", ")}]`;
  if (value instanceof Map) return `{${[...value].map(([key, item]) => `${inspectString(String(key))} => ${rubyInspect(item)}`).join(", ")}}`;
  if (typeof value === "object") return `{${Object.entries(value).map(([key, item]) => `${inspectString(key)} => ${rubyInspect(item)}`).join(", ")}}`;
  return rubyToS(value);
};

const rubyArray = (value: PlistValue | undefined): PlistValue[] => {
  if (value === undefined) return [];
  if (Array.isArray(value)) return value;
  if (value instanceof Map) return [...value].map(([key, item]) => [key, item]);
  return [value];
};

const sameString = (value: PlistValue | undefined, text: string) =>
  typeof value === "string" ? value === text
    : Buffer.isBuffer(value) ? value.equals(Buffer.from(text)) && /^[\x00-\x7f]*$/.test(text)
    : false;

const lookup = (container: PlistValue, key: string): PlistValue | undefined => {
  if (container instanceof Map) return container.get(key);
  if (typeof container === "string" || Buffer.isBuffer(container)) return container.includes(key) ? key : undefined;
  throw new TypeError(`no implicit conversion of String into Integer`);
};

const truthy = (value: unknown) => value !== undefined && value !== null && value !== false;

export const refusal = (profile: PlistDict, certificateSha256: string, bundleId: string, teamId: string): string | undefined => {
  const declared = profile.get("Entitlements");
  const entitlements: PlistValue = truthy(declared) ? declared as PlistValue : new Map();
  const applications = rubyArray(profile.get("ApplicationIdentifierPrefix")).map((prefix) => `${rubyToS(prefix)}.${bundleId}`);
  const application = lookup(entitlements, "application-identifier");
  if (!applications.some((candidate) => sameString(application, candidate))) return `is for ${rubyInspect(application)}`;
  if (!rubyArray(profile.get("TeamIdentifier")).some((team) => sameString(team, teamId))) return "belongs to another team";
  if (profile.has("ProvisionedDevices")) return "lists devices, so it is not an App Store profile";
  if (lookup(entitlements, "get-task-allow") === true) return "allows debugging, so it is not an App Store profile";

  const expiration = profile.get("ExpirationDate");
  if (!(expiration instanceof RubyTime && expiration.isAfterNow())) return `expired at ${rubyInspect(expiration)}`;

  const fingerprints = rubyArray(profile.get("DeveloperCertificates")).map((der) => {
    if (typeof der !== "string" && !Buffer.isBuffer(der)) throw new TypeError("no implicit conversion into String");
    return createHash("sha256").update(der).digest("hex");
  });
  if (!fingerprints.includes(certificateSha256)) return `does not include certificate ${certificateSha256}`;
  if (!/^[0-9A-Fa-f-]{36}$/.test(rubyToS(profile.get("UUID")))) return "has no UUID";

  return undefined;
};

const SYSTEM_ERRORS: Record<string, string> = {
  ENOENT: "No such file or directory @ rb_sysopen",
  EACCES: "Permission denied @ rb_sysopen",
  EISDIR: "Is a directory @ io_fread",
  ENOTDIR: "Not a directory @ rb_sysopen",
};

const fail = (message: string): never => {
  process.stderr.write(`check-signing-profile: ${message}\n`);
  process.exit(1);
};

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

const field = (record: Record<string, unknown>, key: string): unknown => (Object.hasOwn(record, key) ? record[key] : undefined);

const readListing = (listing: string): unknown => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(listing, "utf8"));
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    const known = code ? SYSTEM_ERRORS[code] : undefined;
    return fail(`cannot read ${listing}: ${known ? `${known} - ${listing}` : (error as Error).message}`);
  }
  if (!isRecord(parsed)) throw new TypeError(`undefined method 'fetch' for ${rubyInspect(parsed)}`);
  if (!Object.hasOwn(parsed, "data")) return fail(`cannot read ${listing}: key not found: "data"`);
  return parsed.data;
};

const toArray = (value: unknown): unknown[] => {
  if (value === undefined || value === null) return [];
  if (Array.isArray(value)) return value;
  if (isRecord(value)) return Object.entries(value);
  return [value];
};

const main = (argv: string[]) => {
  if (argv.length !== 5) fail("usage: check-signing-profile.ts <profiles.json> <certificate-sha256> <bundle-id> <team-id> <output>");
  const [listing, sha256, bundleId, teamId, output] = argv as [string, string, string, string, string];
  const certificateSha256 = sha256.toLowerCase();
  const resources = readListing(listing);

  const refusals: string[] = [];
  const matches: { profile: PlistDict; der: Buffer; expiration: RubyTime }[] = [];
  for (const resource of toArray(resources)) {
    const declared = isRecord(resource) ? field(resource, "attributes") : undefined;
    const attributes = isRecord(declared) ? declared : {};
    const name = field(attributes, "name");
    const id = isRecord(resource) ? field(resource, "id") : undefined;
    const label = rubyToS(truthy(name) ? name : truthy(id) ? id : "profile");
    const der = Buffer.from(rubyToS(field(attributes, "profileContent")), "base64");
    let profile: PlistDict;
    try {
      profile = readProfile(der);
    } catch (error) {
      if (!(error instanceof Unreadable)) throw error;
      refusals.push(`${label}: unreadable (${error.message})`);
      continue;
    }
    const reason = refusal(profile, certificateSha256, bundleId, teamId);
    if (reason && !reason.startsWith("is for ")) refusals.push(`${label}: ${reason}`);
    const expiration = profile.get("ExpirationDate");
    if (!reason && expiration instanceof RubyTime) matches.push({ profile, der, expiration });
  }

  if (matches.length === 0) {
    for (const line of refusals) process.stderr.write(`  ${line}\n`);
    fail(`no active App Store profile signs ${bundleId} with certificate ${certificateSha256}`);
  }

  const picked = matches.reduce((best, match) => (match.expiration.compare(best.expiration) > 0 ? match : best));
  writeFileSync(output, picked.der);
  process.stdout.write(`${rubyToS(picked.profile.get("UUID"))}\n`);
};

if (import.meta.main) main(process.argv.slice(2));
