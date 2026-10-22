# Carnap on your own computer

One script runs Carnap from the project's prebuilt image, with its own
Postgres database beside it. You need podman or docker. Nothing to build.

## First time

    git clone https://github.com/smaarmstrong/Carnap.git
    cd Carnap/quickstart
    ./carnap.sh setup

`setup` asks for your Google sign-in details (you can skip them and add
them later), writes them to a private `.env` file with a generated database
password, and starts Carnap at <http://localhost:3000>.

The book at <http://localhost:3000/book> checks exercises at once, with no
account. Accounts are for saved work, courses and assignments.

## Google sign-in

The prebuilt image signs people in through Google only. You need a Google
OAuth client once. The same client works on every computer, because the
address is always `localhost:3000`, so keep the ID and secret somewhere
private, such as a password manager.

1. Open <https://console.cloud.google.com/apis/credentials> in any Google
   Cloud project.
2. If Google asks you to set up the consent screen first: audience
   External, app name Carnap, your email, and add your own Google address
   as a test user.
3. Create credentials, OAuth client ID, type Web application.
4. Authorised redirect URI: `http://localhost:3000/auth/page/google/callback`
5. Put the client ID and secret into `GOOGLEKEY` and `GOOGLESECRET` in
   `.env` (or give them to `setup`), then run `./carnap.sh up`.

Then make yourself admin and instructor:

1. Sign in at <http://localhost:3000> and fill in the registration form.
2. Run `./carnap.sh admin you@gmail.com`

## Everyday commands

| Command | What it does |
| --- | --- |
| `./carnap.sh up` | Start Carnap, or restart it after editing `.env` |
| `./carnap.sh down` | Stop it |
| `./carnap.sh status` | Show whether the two containers are running |
| `./carnap.sh logs` | Last 50 lines from Carnap (`logs 200` for more) |
| `./carnap.sh update` | Fetch the newest Carnap image and restart; data is kept |
| `./carnap.sh admin EMAIL` | Make a signed-in user admin and instructor |
| `./carnap.sh autostart on` | Start Carnap whenever you log in (`off` to stop) |

## Where things live

- `.env`: your settings and secrets. Git ignores it.
- Volume `carnap_pgdata`: the database.
- Volume `carnap_data`: uploaded documents and the session key.

Removing the containers keeps the volumes. Removing the volumes deletes
your data.

## Notes

- Carnap answers on 127.0.0.1 only, so other machines on your network
  cannot reach it.
- The script uses podman if it finds it, otherwise docker. Set
  `CARNAP_ENGINE=docker` to choose.
- Postgres stays on version 13: an existing database cannot move to a new
  major version without a dump and restore.
- Changing `PORT` in `.env` means changing the Google redirect URI to match.
