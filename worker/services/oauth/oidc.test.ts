import { describe, it, expect, vi, afterEach } from 'vitest';
import { OIDCOAuthProvider } from './oidc';

const ISSUER = 'https://auth.example.com/application/o/vibesdk/';

const env = {
	OIDC_ISSUER: ISSUER,
	OIDC_CLIENT_ID: 'vibesdk',
	OIDC_CLIENT_SECRET: 'secret',
} as unknown as Env;

function mockFetch(options: { issuer?: string; userInfo?: Record<string, unknown> }) {
	return vi.fn(async (input: RequestInfo | URL) => {
		const url = typeof input === 'string' ? input : input.toString();
		if (url === 'https://auth.example.com/application/o/vibesdk/.well-known/openid-configuration') {
			return new Response(
				JSON.stringify({
					issuer: options.issuer ?? ISSUER,
					authorization_endpoint: 'https://auth.example.com/application/o/authorize/',
					token_endpoint: 'https://auth.example.com/application/o/token/',
					userinfo_endpoint: 'https://auth.example.com/application/o/userinfo/',
				}),
				{ status: 200 },
			);
		}
		if (url === 'https://auth.example.com/application/o/userinfo/') {
			return new Response(JSON.stringify(options.userInfo ?? {}), { status: 200 });
		}
		throw new Error(`Unexpected fetch to ${url}`);
	});
}

describe('OIDCOAuthProvider', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it('builds the authorization URL from discovery without Google-only parameters', async () => {
		vi.stubGlobal('fetch', mockFetch({}));

		const provider = await OIDCOAuthProvider.create(env, 'https://vibe.example.com');
		const url = new URL(await provider.getAuthorizationUrl('state-1', 'v'.repeat(64)));

		expect(url.origin + url.pathname).toBe('https://auth.example.com/application/o/authorize/');
		expect(url.searchParams.get('redirect_uri')).toBe('https://vibe.example.com/api/auth/callback/oidc');
		expect(url.searchParams.get('code_challenge_method')).toBe('S256');
		expect(url.searchParams.has('prompt')).toBe(false);
		expect(url.searchParams.has('access_type')).toBe(false);
	});

	it('refuses a discovery document for another issuer', async () => {
		vi.stubGlobal('fetch', mockFetch({ issuer: 'https://evil.example.com/' }));

		await expect(OIDCOAuthProvider.create(env, 'https://vibe.example.com')).rejects.toThrow(
			/issuer mismatch/,
		);
	});

	it('treats a missing email_verified claim as unverified', async () => {
		vi.stubGlobal(
			'fetch',
			mockFetch({ userInfo: { sub: 'u1', email: 'a@example.com', preferred_username: 'alice' } }),
		);

		const provider = await OIDCOAuthProvider.create(env, 'https://vibe.example.com');
		const info = await provider.getUserInfo('token');

		expect(info).toMatchObject({ id: 'u1', email: 'a@example.com', name: 'alice' });
		expect(info.emailVerified).toBe(false);
	});

	it('passes a verified email through', async () => {
		vi.stubGlobal(
			'fetch',
			mockFetch({ userInfo: { sub: 'u2', email: 'b@example.com', email_verified: true, name: 'Bob' } }),
		);

		const provider = await OIDCOAuthProvider.create(env, 'https://vibe.example.com');
		const info = await provider.getUserInfo('token');

		expect(info).toMatchObject({ id: 'u2', name: 'Bob', emailVerified: true });
	});
});
