import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { AlertWhatsAppPanel, compactPhone } from "./AlertWhatsAppPanel";
import { stubFetch } from "../../test-utils";

// WhatsApp Phase 1 (configuration only). Fictional numbers only (+1 202-555-01xx).
const RULE_ID = "55555555-5555-4555-8555-555555555555";
const R1 = "99999999-9999-4999-8999-999999999991";
const P0 = "+12025550100";
const P1 = "+12025550101";
const WORDING = { version: "TEST-1", text: "Test-only wording: this person agreed to WhatsApp alert messages." };

function recipient(id: string, phone: string) {
  return {
    recipient_id: id,
    phone_e164: phone,
    phone_masked: "+1 ••••••" + phone.slice(-4),
    consent: { state: "CONFIRMED", confirmed_at: "2026-11-24T06:00:00Z", confirmed_by_name: "Asha Admin", statement_version: "TEST-1" },
  };
}

function config(overrides: Record<string, unknown> = {}) {
  return {
    rule_id: RULE_ID,
    enabled: false,
    revision: 0,
    messages_active: false,
    max_recipients: 10,
    recipients: [],
    consent_statement: WORDING,
    ...overrides,
  };
}

type Call = { url: string; method: string; body: unknown };
type PutBody = { enabled: boolean; revision: number; recipients: { recipient_id: string | null; phone: string }[] };

/** What the server returns after a save: the stored configuration. */
function saved(body: PutBody) {
  return config({
    enabled: body.enabled,
    revision: body.revision + 1,
    recipients: body.recipients.map((r, i) => recipient(r.recipient_id ?? `new-${i}`, r.phone)),
  });
}

function api(initial: Record<string, unknown>, onPut?: (body: unknown) => { status?: number; jsonBody?: unknown }) {
  const calls: Call[] = [];
  stubFetch((url, init) => {
    const call = { url, method: init?.method ?? "GET", body: init?.body ? JSON.parse(String(init.body)) : undefined };
    calls.push(call);
    if (call.method === "PUT") return onPut?.(call.body) ?? { jsonBody: saved(call.body as PutBody) };
    return { jsonBody: initial };
  });
  return calls;
}

async function panel() {
  render(<AlertWhatsAppPanel ruleId={RULE_ID} />);
  return screen.findByTestId("whatsapp-enabled");
}

function addNumber(code: string, number: string) {
  fireEvent.change(screen.getByTestId("whatsapp-country-code"), { target: { value: code } });
  fireEvent.change(screen.getByTestId("whatsapp-number"), { target: { value: number } });
  fireEvent.click(screen.getByTestId("whatsapp-add"));
}

const puts = (calls: Call[]) => calls.filter((c) => c.method === "PUT");

describe("AlertWhatsAppPanel (WhatsApp Phase 1)", () => {
  it("always says messages are not sent, and hides the numbers while off", async () => {
    const calls = api(config());
    await panel();
    expect(screen.getByTestId("whatsapp-not-sent").textContent).toContain("WhatsApp messages are not sent yet");
    expect(screen.queryByTestId("whatsapp-recipients")).toBeNull();
    expect(calls[0]!.url).toBe(`/api/v1/alert-rules/${RULE_ID}/whatsapp`);
    expect(screen.getByTestId("whatsapp-save")).toBeDisabled(); // nothing changed yet
  });

  it("adds a number with its country code, needs the opt-in confirmation, and saves on its own", async () => {
    const calls = api(config());
    fireEvent.click(await panel());
    expect(screen.getByTestId("whatsapp-status").textContent).toBe("Unsaved WhatsApp changes");
    addNumber("+1", "202 555 0100");
    expect(screen.getByTestId("whatsapp-phone-0").textContent).toBe(P0);
    // The approved wording, from the server, is what the administrator confirms.
    expect(screen.getByTestId("whatsapp-consent-text-0").textContent).toBe(WORDING.text);

    fireEvent.click(screen.getByTestId("whatsapp-save"));
    expect((await screen.findByTestId("whatsapp-row-error-0")).textContent).toContain("Confirm that this person agreed");
    expect(puts(calls)).toEqual([]);

    fireEvent.click(screen.getByTestId("whatsapp-consent-0"));
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    await waitFor(() => expect(puts(calls)).toHaveLength(1));
    expect(puts(calls)[0]!.url).toBe(`/api/v1/alert-rules/${RULE_ID}/whatsapp`);
    expect(puts(calls)[0]!.body).toEqual({
      enabled: true,
      revision: 0,
      consent_statement_version: "TEST-1",
      recipients: [{ recipient_id: null, phone: P0, opt_in_confirmed: true }],
    });
    expect((await screen.findByTestId("whatsapp-status")).textContent).toBe("WhatsApp settings saved.");
  });

  it("shows field errors for an invalid or duplicate number and does not add it", async () => {
    api(config({ enabled: true, revision: 1, recipients: [recipient(R1, P0)] }));
    await panel();
    addNumber("+1", "12");
    expect(screen.getByTestId("whatsapp-add-error").textContent).toBe("Enter a valid mobile number with its country code.");
    addNumber("+1", "(202) 555-0100");
    expect(screen.getByTestId("whatsapp-add-error").textContent).toBe("This number is already in the list.");
    expect(screen.queryByTestId("whatsapp-row-1")).toBeNull();
  });

  it("keeps an unchanged number's consent and sends a changed number for fresh confirmation", async () => {
    const calls = api(config({ enabled: true, revision: 4, recipients: [recipient(R1, P0)] }));
    await panel();
    expect(within(screen.getByTestId("whatsapp-row-0")).getByText(/Opt-in confirmed by Asha Admin/)).toBeTruthy();
    expect(screen.queryByTestId("whatsapp-consent-0")).toBeNull();
    fireEvent.click(screen.getByTestId("whatsapp-edit-0"));
    fireEvent.change(screen.getByTestId("whatsapp-edit-input-0"), { target: { value: P1 } });
    expect(screen.getByTestId("whatsapp-consent-0")).toBeTruthy();
    fireEvent.click(screen.getByTestId("whatsapp-consent-0"));
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    await waitFor(() => expect(puts(calls)).toHaveLength(1));
    expect(puts(calls)[0]!.body).toEqual({
      enabled: true,
      revision: 4,
      consent_statement_version: "TEST-1",
      recipients: [{ recipient_id: R1, phone: P1, opt_in_confirmed: true }],
    });
  });

  it("removes a number and keeps the rest unchanged", async () => {
    const calls = api(config({ enabled: true, revision: 2, recipients: [recipient(R1, P0), recipient("r2", P1)] }));
    await panel();
    fireEvent.click(screen.getByTestId("whatsapp-remove-1"));
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    await waitFor(() => expect(puts(calls)).toHaveLength(1));
    expect((puts(calls)[0]!.body as { recipients: unknown }).recipients).toEqual([
      { recipient_id: R1, phone: P0, opt_in_confirmed: false },
    ]);
  });

  it("keeps the numbers when WhatsApp is switched off", async () => {
    const calls = api(config({ enabled: true, revision: 2, recipients: [recipient(R1, P0)] }));
    fireEvent.click(await panel());
    expect(screen.getByTestId("whatsapp-kept-note").textContent).toBe("1 number is kept while WhatsApp is off.");
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    await waitFor(() => expect(puts(calls)).toHaveLength(1));
    expect(puts(calls)[0]!.body).toMatchObject({ enabled: false, recipients: [{ recipient_id: R1, phone: P0 }] });
  });

  it("refuses to turn WhatsApp on with no numbers", async () => {
    const calls = api(config());
    fireEvent.click(await panel());
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    expect((await screen.findByTestId("whatsapp-error")).textContent).toContain("Add at least one number");
    expect(puts(calls)).toEqual([]);
  });

  it("cannot add or edit numbers while no opt-in wording is approved", async () => {
    api(config({ enabled: true, revision: 1, recipients: [recipient(R1, P0)], consent_statement: null }));
    await panel();
    expect(screen.getByTestId("whatsapp-no-wording").textContent).toContain("opt-in confirmation wording has not been approved");
    expect(screen.queryByTestId("whatsapp-add")).toBeNull();
    expect(screen.getByTestId("whatsapp-edit-0")).toBeDisabled();
    expect(screen.getByTestId("whatsapp-remove-0")).not.toBeDisabled(); // removing needs no consent
  });

  it("stops at ten numbers", async () => {
    const ten = Array.from({ length: 10 }, (_, i) => recipient(`r${i}`, `+1202555${String(100 + i).padStart(4, "0")}`));
    api(config({ enabled: true, revision: 1, recipients: ten }));
    await panel();
    expect(screen.getByTestId("whatsapp-limit").textContent).toBe("This alert has the maximum of 10 WhatsApp numbers.");
    expect(screen.queryByTestId("whatsapp-add")).toBeNull();
  });

  it("keeps the entered settings after a refused save and offers a reload on a conflict", async () => {
    api(config(), () => ({
      status: 409,
      jsonBody: { error: "whatsapp_config_stale", detail: "These WhatsApp settings were changed by someone else. Reload them and try again." },
    }));
    fireEvent.click(await panel());
    addNumber("+1", "2025550100");
    fireEvent.click(screen.getByTestId("whatsapp-consent-0"));
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    expect((await screen.findByTestId("whatsapp-error")).textContent).toContain("changed by someone else");
    expect(screen.getByTestId("whatsapp-reload")).toBeTruthy();
    expect(screen.getByTestId("whatsapp-phone-0").textContent).toBe(P0); // nothing lost
    expect(screen.getByTestId("whatsapp-status").textContent).toBe("Unsaved WhatsApp changes");
  });

  it("shows the server's refusal when the wording was not approved after all", async () => {
    api(config(), () => ({
      status: 422,
      jsonBody: {
        error: "whatsapp_consent_statement_missing",
        detail: "New WhatsApp numbers cannot be added yet: the opt-in confirmation wording has not been approved.",
      },
    }));
    fireEvent.click(await panel());
    addNumber("+1", "2025550100");
    fireEvent.click(screen.getByTestId("whatsapp-consent-0"));
    fireEvent.click(screen.getByTestId("whatsapp-save"));
    expect((await screen.findByTestId("whatsapp-error")).textContent).toContain("wording has not been approved");
    expect(screen.queryByTestId("whatsapp-reload")).toBeNull();
  });

  it("never submits a surrounding rule form when Enter is pressed in it", async () => {
    api(config({ enabled: true, revision: 1 }));
    const onSubmit = vi.fn((e: { preventDefault: () => void }) => e.preventDefault());
    render(
      <form onSubmit={onSubmit}>
        <AlertWhatsAppPanel ruleId={RULE_ID} />
      </form>,
    );
    const input = await screen.findByTestId("whatsapp-number");
    fireEvent.change(screen.getByTestId("whatsapp-country-code"), { target: { value: "+1" } });
    fireEvent.change(input, { target: { value: "2025550101" } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onSubmit).not.toHaveBeenCalled();
    expect(screen.getByTestId("whatsapp-phone-0").textContent).toBe(P1); // Enter adds the number instead
  });

  it("shows a load error with a retry", async () => {
    stubFetch(() => ({ status: 403, jsonBody: { error: "forbidden", detail: "You do not have permission to do this." } }));
    render(<AlertWhatsAppPanel ruleId={RULE_ID} />);
    expect((await screen.findByTestId("whatsapp-load-error")).textContent).toContain("You do not have permission");
  });
});

describe("compactPhone", () => {
  it("removes spaces, dashes, dots and brackets only", () => {
    expect(compactPhone("+1 (202) 555-01.00")).toBe(P0);
  });
});
