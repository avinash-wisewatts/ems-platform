# User management and sign-in — manual browser checklist

Status: CURRENT · 2026-11-04 · Manual, by an operator (no browser automation).

When to run:
- on **staging** after each deployment that touches user management, sign-in or the host split (migrations 315–319, ADR-023 Amendments 2–3);
- on production after a release that contains it (production has no customer host; only sections A, E and F apply there).

Accounts:
- a staff administrator (ADMIN, GLOBAL);
- a **test** customer account (ORGANIZATION or SELECTED_SITES), created in step A3;
- where noted, a second test account.

Do not change real customer accounts. Use test accounts and revert what you change.

Staging addresses:
- Administration App: `http://16.113.18.69:8080`
- Customer host (EMS Web App): `https://16.113.18.69`

## A. Administration App — users (`/administration/users`)

1. **List.** Sign in as the staff administrator.
   - The Users list loads with role, scope and status, with no error banner.
   - Search, the Role and Status filters and the **Organization** filter (staff only) narrow the list.
2. **Your own account.** Open your own row.
   - There is no reset-password form; the page offers **Change my password** instead.
   - On *Edit access*, changing your own role, scope or status is refused with a clear message, and nothing changes after a reload.
3. **Create a test user**, with *Generate a temporary password*.
   - The temporary password is shown **once**, on that page only.
   - After a reload, or on the user's page, it is gone and doesn't appear in the page source.
   - Create a second test user with *Set a password*:
     - a password under 12 characters, or equal to the username, is refused;
     - a valid password is accepted, and no password is shown.
4. **Detail page** of a test user. You can see:
   - username, created / changed times, organization and site names;
   - **Change history** with *Account created*, by you.
5. **Edit name and e-mail.**
   - An invalid e-mail is refused.
   - A valid change is saved and appears in Change history as *Name or e-mail changed*, with the before → after values.
6. **Role, scope and status** (Edit access) on a test user:
   - change the role, then change it back;
   - deactivate the user, then activate them again.

   Each change appears in Change history.
7. **Reset password** of a test user.
   - Generated: shown once.
   - Set: the confirmation must match.
   - The page warns that already-signed-in sessions stay valid (issue #172).
   - The history shows *Password reset by an administrator* and *Failed-sign-in lockout cleared*.
8. **Another ADMIN** (test account).
   - Resetting their password is allowed for staff.
   - As an organization-level administrator (if a test one exists), there is no reset form, and the history shows no other organization's entries or ids.
9. **Change my password** (header link, any role).
   - A wrong current password is refused.
   - Mismatched new passwords are refused.
   - The correct current password changes it. Use a test account, or change it back.
   - After 5 wrong attempts the account is locked: even the correct password is refused until the lock expires.

## B. Administration App — no web app here (staging)

10. **`http://16.113.18.69:8080/app/`** returns **404**, both signed in and signed out, with the text "served on the customer host". There is no redirect to `/login`.
11. **Sign-in never lands on `/app`:** signing in at `:8080/login?next_path=/app/` goes to the Administration App instead.

## C. Customer host — customer (`https://16.113.18.69/app/`)

12. **Sign in** with the test customer account (step A3).
    - Its sites and data load.
    - There is no Admin entry in the menu.
13. **`/app/account/password`** explains that the password is changed by an administrator. On the customer host, a password change goes through the Administration App, as in A7.

## D. Customer host — staff (`EMS_CUSTOMER_ALLOW_STAFF=true` on staging)

14. **Staff sign-in.** Sign in at `https://16.113.18.69/app/` as the staff administrator (GLOBAL).
    - The sign-in succeeds.
    - Organizations and sites across tenants are readable.
    - There is **no Admin section**, and nothing can be changed.
15. **Admin paths stay closed:**
    - `/app/admin/users` shows no user list (permission page);
    - `https://16.113.18.69/api/admin/v1/users`, `/administration/users` and `/login` return **404**.
16. **Independent sessions.**
    - Signing out of the customer host does not sign you out of `:8080`, and the other way round.
    - Live data (Live tiles) updates for staff.

## E. Sessions (known limitation, issue #172)

17. **Reset while signed in.**
    - Sign in as a test user in a second browser on `:8080`, then reset that user's password from the first browser.
    - The second browser **stays signed in** until the session expires or signs out. This is the documented limitation, not a regression.
    - On the customer host the reset ends that user's customer sessions (Amendment 1).
    - To cut off a compromised account today: reset the password **and** deactivate the account.

## F. Browser storage and logs

18. **Storage.** In DevTools → Application there is no password, hash or reset token in Local Storage, Session Storage or cookies, other than the session cookies (HttpOnly).
19. **Console.** In DevTools → Console there are no errors on the pages above.

Record date, environment, account used and pass / fail per item.
