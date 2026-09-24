/**
 * Generic OpenID Connect provider (Authentik, Keycloak, Dex and the like),
 * configured through OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET.
 * Endpoints come from the issuer's discovery document.
 */

import { BaseOAuthProvider } from './base';
import type { OAuthUserInfo } from '../../types/auth-types';
import { OAuthProvider } from '../../types/auth-types';
import { createLogger } from '../../logger';

const logger = createLogger('OIDCOAuth');

interface DiscoveryDocument {
    issuer: string;
    authorization_endpoint: string;
    token_endpoint: string;
    userinfo_endpoint: string;
}

interface UserInfoResponse {
    sub: string;
    email?: string;
    email_verified?: boolean;
    name?: string;
    preferred_username?: string;
    picture?: string;
}

export class OIDCOAuthProvider extends BaseOAuthProvider {
    protected readonly provider: OAuthProvider = 'oidc';
    protected readonly scopes = ['openid', 'email', 'profile'];
    // Google's offline access and forced consent mean nothing to a generic
    // provider, and `prompt=consent` makes some of them show a consent screen.
    protected override readonly authorizationParams: Record<string, string> = {};

    constructor(
        clientId: string,
        clientSecret: string,
        redirectUri: string,
        protected readonly authorizationUrl: string,
        protected readonly tokenUrl: string,
        protected readonly userInfoUrl: string
    ) {
        super(clientId, clientSecret, redirectUri);
    }

    static isConfigured(env: Env): boolean {
        return !!env.OIDC_ISSUER && !!env.OIDC_CLIENT_ID && !!env.OIDC_CLIENT_SECRET;
    }

    static async create(env: Env, baseUrl: string): Promise<OIDCOAuthProvider> {
        const { OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET } = env;
        if (!OIDC_ISSUER || !OIDC_CLIENT_ID || !OIDC_CLIENT_SECRET) {
            throw new Error('OIDC credentials not configured');
        }

        const issuer = OIDC_ISSUER.replace(/\/+$/, '');
        const response = await fetch(`${issuer}/.well-known/openid-configuration`, {
            headers: { Accept: 'application/json' },
        });
        if (!response.ok) {
            throw new Error(`OIDC discovery failed: ${response.status}`);
        }
        const discovery = (await response.json()) as DiscoveryDocument;
        // OIDC Discovery 1.0, section 4.3: the document must name the issuer it was fetched for.
        if (discovery.issuer.replace(/\/+$/, '') !== issuer) {
            throw new Error(`OIDC discovery issuer mismatch: ${discovery.issuer}`);
        }

        return new OIDCOAuthProvider(
            OIDC_CLIENT_ID,
            OIDC_CLIENT_SECRET,
            `${baseUrl}/api/auth/callback/oidc`,
            discovery.authorization_endpoint,
            discovery.token_endpoint,
            discovery.userinfo_endpoint
        );
    }

    async getUserInfo(accessToken: string): Promise<OAuthUserInfo> {
        const response = await fetch(this.userInfoUrl, {
            headers: {
                Authorization: `Bearer ${accessToken}`,
                Accept: 'application/json',
            },
        });
        if (!response.ok) {
            const error = await response.text();
            logger.error('Failed to get user info', { error });
            throw new Error(`Failed to get user info: ${error}`);
        }

        const data = (await response.json()) as UserInfoResponse;
        if (!data.sub || !data.email) {
            throw new Error('OIDC user info lacks sub or email');
        }

        return {
            id: data.sub,
            email: data.email,
            name: data.name || data.preferred_username,
            picture: data.picture,
            emailVerified: data.email_verified === true,
        };
    }
}
