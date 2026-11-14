import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import type { NewPasskey, StoredPasskey } from "./store.ts";

/**
 * WebAuthn behind an interface: the real implementation uses SimpleWebAuthn,
 * tests use a fake so the whole OAuth flow is testable without a browser.
 */
export interface PasskeyService {
  registrationOptions(input: { userId: string; userName: string }): Promise<
    { options: Record<string, unknown>; challenge: string }
  >;
  verifyRegistration(input: { response: unknown; expectedChallenge: string }): Promise<
    NewPasskey | null
  >;
  authenticationOptions(): Promise<{ options: Record<string, unknown>; challenge: string }>;
  /** Returns the credential id asserted by the client (to look the passkey up). */
  credentialIdOf(response: unknown): string | null;
  verifyAuthentication(input: {
    response: unknown;
    expectedChallenge: string;
    passkey: StoredPasskey;
  }): Promise<{ newCounter: number } | null>;
}

export function createWebAuthnPasskeys(cfg: {
  rpId: string;
  rpName: string;
  origin: string;
}): PasskeyService {
  return {
    async registrationOptions({ userId, userName }) {
      const options = await generateRegistrationOptions({
        rpName: cfg.rpName,
        rpID: cfg.rpId,
        userName,
        userDisplayName: userName,
        userID: new TextEncoder().encode(userId),
        attestationType: "none",
        authenticatorSelection: { residentKey: "required", userVerification: "preferred" },
      });
      return {
        options: options as unknown as Record<string, unknown>,
        challenge: options.challenge,
      };
    },

    async verifyRegistration({ response, expectedChallenge }) {
      try {
        const result = await verifyRegistrationResponse({
          // deno-lint-ignore no-explicit-any
          response: response as any,
          expectedChallenge,
          expectedOrigin: cfg.origin,
          expectedRPID: cfg.rpId,
          requireUserVerification: false,
        });
        if (!result.verified || !result.registrationInfo) return null;
        const { credential, credentialDeviceType, credentialBackedUp } = result.registrationInfo;
        return {
          id: credential.id,
          publicKey: credential.publicKey,
          counter: credential.counter,
          transports: credential.transports ?? [],
          deviceType: credentialDeviceType,
          backedUp: credentialBackedUp,
        };
      } catch {
        return null;
      }
    },

    async authenticationOptions() {
      const options = await generateAuthenticationOptions({
        rpID: cfg.rpId,
        userVerification: "preferred",
      });
      return {
        options: options as unknown as Record<string, unknown>,
        challenge: options.challenge,
      };
    },

    credentialIdOf(response) {
      const id = (response as { id?: unknown })?.id;
      return typeof id === "string" && id.length > 0 ? id : null;
    },

    async verifyAuthentication({ response, expectedChallenge, passkey }) {
      try {
        const result = await verifyAuthenticationResponse({
          // deno-lint-ignore no-explicit-any
          response: response as any,
          expectedChallenge,
          expectedOrigin: cfg.origin,
          expectedRPID: cfg.rpId,
          requireUserVerification: false,
          credential: {
            id: passkey.id,
            publicKey: passkey.publicKey as Uint8Array<ArrayBuffer>,
            counter: passkey.counter,
            // deno-lint-ignore no-explicit-any
            transports: passkey.transports as any,
          },
        });
        return result.verified ? { newCounter: result.authenticationInfo.newCounter } : null;
      } catch {
        return null;
      }
    },
  };
}
