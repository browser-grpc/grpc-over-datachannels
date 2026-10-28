# Google Drive setup (one-time, project owner)

The web app can save/open `.proto` schemas in each visitor's own
Google Drive. It ships with one OAuth client ID (public config,
registered for this site's origin); every visitor signs in with
their own Google account and the app only ever sees files it
created or the user opened through it (`drive.file` scope).
Tokens are issued by Google Identity Services and stay in the
tab — there is no backend and nothing to rotate.

## Create the client ID

1. [Google Cloud Console](https://console.cloud.google.com/) →
   create (or pick) a project.
2. **APIs & Services → Library** → enable **Google Drive API**.
3. **APIs & Services → OAuth consent screen**: External, app name
   e.g. "grpc-dc stub generator". Add the scope
   `.../auth/drive.file` (non-sensitive — no verification review
   needed). Publish the consent screen to production so anyone
   with a Google account can use it.
4. **APIs & Services → Credentials → Create credentials → OAuth
   client ID** → type **Web application**. Authorized JavaScript
   origins:
   - `https://browser-grpc.github.io`
   - `http://localhost:8006` (local `make webapp-serve` dev)
5. Copy the client ID
   (`NNNNNNNNNNNN-xxxx.apps.googleusercontent.com`) into
   `GOOGLE_OAUTH_CLIENT_ID` in `webapp/app.js`, regenerate the
   webapp bundle, and republish.

Until step 5 lands, the Drive buttons explain that Drive is not
configured for the deployment; local upload/edit/generate flows
are unaffected.

## Notes

- Quotas are per-project (Drive API default quotas are ample for
  schema files).
- The app never requests full-Drive access; files saved by other
  apps are invisible to it, by design.
- To revoke: the user disconnects the app under their Google
  Account → Security → third-party access.
