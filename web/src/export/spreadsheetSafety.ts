/**
 * Spreadsheet formula-injection protection for CSV exports (CWE-1236; OWASP
 * CSV injection guidance). Shared by the Energy export (Q75) and the
 * Analytics export (F7) so both apply one rule.
 *
 * A text cell that starts with `=`, `+`, `-`, `@`, a tab or a line break can
 * be evaluated as a formula when the CSV is opened in a spreadsheet. Such a
 * cell is prefixed with `'`, which makes the spreadsheet show it as text.
 *
 * Numbers are never prefixed: a number value is left alone, and so is a
 * string that is a plain decimal number (exports format some values as
 * strings, e.g. `(-3.5).toFixed(1)` is "-3.5"), so a negative value stays a
 * number. Escaping for the CSV format itself (quotes, commas, line breaks)
 * stays with the caller's field writer.
 */

const FORMULA_START = /^[=+\-@\t\r\n]/;
const PLAIN_DECIMAL = /^-?\d+(\.\d+)?$/;

/** A text cell made inert for spreadsheets: a leading formula character is
 *  escaped with `'`. Only for text that is never a number. */
export function neutralizeSpreadsheetText(text: string): string {
  return FORMULA_START.test(text) ? `'${text}` : text;
}

/** Any CSV cell value made safe: strings are neutralized unless they are a
 *  plain decimal number; numbers, booleans and null pass through unchanged. */
export function spreadsheetSafeCell<T>(value: T): T | string {
  if (typeof value !== "string" || PLAIN_DECIMAL.test(value)) return value;
  return neutralizeSpreadsheetText(value);
}
