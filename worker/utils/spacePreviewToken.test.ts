import { describe, expect, it } from 'vitest';
import { JWTUtils } from './jwtUtils';
import {
	buildPreviewCookie,
	readPreviewCookie,
	signSpacePreviewToken,
	SPACE_PREVIEW_COOKIE_NAME,
	verifySpacePreviewToken,
} from './spacePreviewToken';

const testEnv = {
	JWT_SECRET: 'test-secret-for-space-preview-token-validation-1234567890',
};

describe('spacePreviewToken', () => {
	it('verifies a valid signed token', async () => {
		const token = await signSpacePreviewToken(testEnv, {
			spaceName: 'space-a',
			branch: 'main',
			userId: 'user-a',
			previewVersion: 3,
		});

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-a', 'main');
		expect(claims).toEqual({
			spaceName: 'space-a',
			branch: 'main',
			userId: 'user-a',
			previewVersion: 3,
			expiresAt: expect.any(Number),
		});
	});

	it('verifies a share token minted without expiry', async () => {
		const token = await signSpacePreviewToken(
			testEnv,
			{ spaceName: 'space-a', branch: 'main', userId: 'user-a', previewVersion: 0 },
			null,
		);

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-a', 'main');
		expect(claims?.expiresAt).toBeNull();
	});

	it('rejects a token missing previewVersion', async () => {
		const jwt = JWTUtils.getInstance(testEnv);
		const token = await jwt.signPayload(
			{
				spaceName: 'space-a',
				branch: 'main',
				userId: 'user-a',
				purpose: 'space_preview',
			},
			60,
		);

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-a', 'main');
		expect(claims).toBeNull();
	});

	it('rejects token for a different space', async () => {
		const token = await signSpacePreviewToken(testEnv, {
			spaceName: 'space-a',
			branch: 'main',
			userId: 'user-a',
			previewVersion: 0,
		});

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-b', 'main');
		expect(claims).toBeNull();
	});

	it('rejects token for a different branch', async () => {
		const token = await signSpacePreviewToken(testEnv, {
			spaceName: 'space-a',
			branch: 'main',
			userId: 'user-a',
			previewVersion: 0,
		});

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-a', 'feature');
		expect(claims).toBeNull();
	});

	it('rejects token with wrong purpose', async () => {
		const jwt = JWTUtils.getInstance(testEnv);
		const token = await jwt.signPayload(
			{
				spaceName: 'space-a',
				branch: 'main',
				userId: 'user-a',
				purpose: 'not-space-preview',
			},
			60,
		);

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-a', 'main');
		expect(claims).toBeNull();
	});

	it('rejects expired token', async () => {
		const jwt = JWTUtils.getInstance(testEnv);
		const token = await jwt.signPayload(
			{
				spaceName: 'space-a',
				branch: 'main',
				userId: 'user-a',
				purpose: 'space_preview',
			},
			-1,
		);

		const claims = await verifySpacePreviewToken(testEnv, token, 'space-a', 'main');
		expect(claims).toBeNull();
	});
});

describe('preview cookie helpers', () => {
	it('builds a Lax cookie for same-origin (no Secure over http)', () => {
		const cookie = buildPreviewCookie({
			token: 'abc',
			spaceName: 'space-a',
			branch: 'main',
			crossSite: false,
			secure: false,
			expiresAt: null,
		});
		expect(cookie).toContain(`${SPACE_PREVIEW_COOKIE_NAME}=abc`);
		expect(cookie).toContain('Path=/space/space-a/preview/main');
		expect(cookie).toContain('HttpOnly');
		expect(cookie).toContain('SameSite=Lax');
		expect(cookie).not.toContain('Secure');
		expect(cookie).not.toContain('Partitioned');
	});

	it('builds a None;Secure;Partitioned cookie for a separate preview domain', () => {
		const cookie = buildPreviewCookie({
			token: 'abc',
			spaceName: 'space-a',
			branch: 'main',
			crossSite: true,
			secure: true,
			expiresAt: null,
		});
		expect(cookie).toContain('SameSite=None');
		expect(cookie).toContain('Secure');
		expect(cookie).toContain('Partitioned');
	});

	it('encodes the cookie path and avoids a trailing slash', () => {
		const cookie = buildPreviewCookie({
			token: 'abc',
			spaceName: 'my space',
			branch: 'feat/x',
			crossSite: false,
			secure: true,
			expiresAt: null,
		});
		expect(cookie).toContain('Path=/space/my%20space/preview/feat%2Fx');
	});

	it('lets the cookie expire with its token, or last the session without expiry', () => {
		const now = Math.floor(Date.now() / 1000);
		const base = { token: 'abc', spaceName: 'space-a', branch: 'main', crossSite: false, secure: true };
		expect(buildPreviewCookie({ ...base, expiresAt: now + 600 })).toMatch(/Max-Age=(599|600);/);
		expect(buildPreviewCookie({ ...base, expiresAt: now - 5 })).toContain('Max-Age=0;');
		expect(buildPreviewCookie({ ...base, expiresAt: null })).not.toContain('Max-Age');
	});

	it('reads the preview cookie value from the Cookie header', () => {
		const request = new Request('https://example.com/', {
			headers: { Cookie: `other=1; ${SPACE_PREVIEW_COOKIE_NAME}=tok123; foo=bar` },
		});
		expect(readPreviewCookie(request)).toBe('tok123');
	});

	it('returns null when no preview cookie is present', () => {
		const request = new Request('https://example.com/', {
			headers: { Cookie: 'other=1' },
		});
		expect(readPreviewCookie(request)).toBeNull();
	});
});
