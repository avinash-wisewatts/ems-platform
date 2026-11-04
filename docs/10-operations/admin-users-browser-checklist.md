# Admin → Users — manual browser checklist

Status: CURRENT · 2026-11-04 · Manual, by an operator (no browser automation).
Run on **staging** after each deployment of the user-management changes
(migrations 315–318), and on production after the release. Use a staff
administrator account (ADMIN, GLOBAL) and, where noted, a second test account.
Do not change real customer accounts; use test accounts and revert what you
change.

Staging: Administration App `http://16.113.18.69:8080`; customer host
`https://16.113.18.69`.

## A. Administration App — existing Users pages (`/administration/users`)

1. Sign in as the staff administrator. The Users list loads with roles,
   scopes and status; no error banner.
2. Open your **own** row. Try to change your role, access scope or status:
   each is refused with a clear message ("cannot change their own …"); nothing
   changes after a page reload.
3. On a **test** user inside your scope: change the role, then change it back;
   both succeed and the list shows the change.
4. Reset a **test** user's password: succeeds; the new password is shown or
   handed over once only; it never appears in the page source afterwards.
5. Reset another **ADMIN**'s password (test account): allowed for a staff
   (GLOBAL) administrator. As an organization-level administrator (if a test
   one exists) it must be refused with "Only WiseWatts staff administrators …".

## B. EMS Web App — Admin → Users (`/app/admin/users`, staff path)

6. The list and a user's detail page load; scope and status are shown.
7. On your own detail page, role / scope / status controls are disabled or
   refused.
8. The user menu shows **Change password**; `/app/account/password` opens.
   A wrong current password is refused; the correct one changes it (use a test
   account, or change it back).
9. After 5 wrong current-password attempts the account is locked: even the
   correct password is refused until the lock expires.

## C. Customer host isolation (`https://16.113.18.69`)

10. `/app/account/password` shows "not available here"; no Admin menu entry.
11. `/administration/users` and `/api/admin/v1/users` return 404.

## D. Sessions (known limitation, issue #172)

12. Sign in as a test user in a second browser. Reset that user's password
    from the first browser. The second browser **stays signed in** until the
    session expires or signs out — this is the documented limitation, not a
    regression. To cut off a compromised account today: reset the password
    **and** deactivate the account.

## E. Browser storage and logs

13. DevTools → Application: no password, hash or reset token in Local /
    Session Storage or cookies other than the session cookie (HttpOnly).
14. DevTools → Console: no errors on the pages above.

Record date, environment, account used and pass / fail per item.
