import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { downloadCsv, downloadTextFile } from "./downloadCsv";

/**
 * Thin DOM-invocation test only -- mirrors reports/pdf.ts's own precedent
 * of not unit-testing the actual browser download mechanism byte-for-byte
 * (jsPDF's `.save()` is untested there too). This confirms
 * downloadTextFile/downloadCsv invoke the browser download primitives
 * correctly (anchor created, clicked, filename set, object URL revoked) --
 * not that a real file lands on a real filesystem, which jsdom cannot
 * observe anyway.
 */
describe("downloadTextFile / downloadCsv", () => {
  let createObjectURLSpy: ReturnType<typeof vi.fn>;
  let revokeObjectURLSpy: ReturnType<typeof vi.fn>;
  let clickSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    createObjectURLSpy = vi.fn(() => "blob:mock-url");
    revokeObjectURLSpy = vi.fn();
    URL.createObjectURL = createObjectURLSpy as unknown as typeof URL.createObjectURL;
    URL.revokeObjectURL = revokeObjectURLSpy as unknown as typeof URL.revokeObjectURL;
    clickSpy = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  });

  afterEach(() => {
    clickSpy.mockRestore();
  });

  it("creates an object URL from a Blob of the given content and mime type", () => {
    downloadTextFile("test.csv", "a,b\r\n1,2\r\n", "text/csv;charset=utf-8;");
    expect(createObjectURLSpy).toHaveBeenCalledTimes(1);
    const blob = createObjectURLSpy.mock.calls[0]?.[0] as Blob;
    expect(blob.type).toBe("text/csv;charset=utf-8;");
  });

  it("sets the anchor's download attribute to the given filename and clicks it", () => {
    downloadTextFile("my-export.csv", "x", "text/csv;charset=utf-8;");
    expect(clickSpy).toHaveBeenCalledTimes(1);
  });

  it("revokes the object URL after triggering the download", () => {
    downloadTextFile("test.csv", "x", "text/csv;charset=utf-8;");
    expect(revokeObjectURLSpy).toHaveBeenCalledWith("blob:mock-url");
  });

  it("downloadCsv passes the CSV mime type through to downloadTextFile", () => {
    downloadCsv("export.csv", "a,b\r\n1,2\r\n");
    const blob = createObjectURLSpy.mock.calls[0]?.[0] as Blob;
    expect(blob.type).toBe("text/csv;charset=utf-8;");
  });
});
