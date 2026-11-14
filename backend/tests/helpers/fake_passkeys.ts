import { base64url } from "../../src/auth/crypto.ts";
import type { PasskeyService } from "../../src/auth/passkeys.ts";

/**
 * Accepts a "credential" of the shape { id, challenge } — the test plays the authenticator by
 * echoing the challenge it was given. Everything else (DB, OAuth, MCP) is real.
 */
export function fakePasskeys(): PasskeyService {
  const newChallenge = () => base64url(crypto.getRandomValues(new Uint8Array(16)));
  const echo = (r: unknown) => r as { id?: string; challenge?: string };
  return {
    registrationOptions({ userId, userName }) {
      const challenge = newChallenge();
      return Promise.resolve({
        challenge,
        options: {
          challenge,
          user: { id: base64url(new TextEncoder().encode(userId)), name: userName },
        },
      });
    },
    verifyRegistration({ response, expectedChallenge }) {
      const r = echo(response);
      if (!r.id || r.challenge !== expectedChallenge) return Promise.resolve(null);
      return Promise.resolve({
        id: r.id,
        publicKey: new Uint8Array([1, 2, 3]),
        counter: 0,
        transports: ["internal"],
      });
    },
    authenticationOptions() {
      const challenge = newChallenge();
      return Promise.resolve({ challenge, options: { challenge } });
    },
    credentialIdOf: (r) => echo(r).id ?? null,
    verifyAuthentication({ response, expectedChallenge, passkey }) {
      return Promise.resolve(
        echo(response).challenge === expectedChallenge ? { newCounter: passkey.counter + 1 } : null,
      );
    },
  };
}
