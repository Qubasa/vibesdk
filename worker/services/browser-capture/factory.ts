/**
 * Selects the right `BrowserCaptureClient` for the current runtime
 * environment. In dev, and on self-hosted deployments without the
 * Cloudflare `BROWSER` binding, we hit a local sidecar that runs
 * puppeteer natively; otherwise we use the `BROWSER` binding directly.
 */

import { isDev } from '../../utils/envs';
import type { StructuredLogger } from '../../logger';
import { BindingCaptureClient } from './binding-client';
import { SidecarCaptureClient } from './sidecar-client';
import type { BrowserCaptureClient } from './types';

export function getBrowserCaptureClient(
	env: Env,
	logger: StructuredLogger,
): BrowserCaptureClient {
	return isDev(env) || !env.BROWSER
		? new SidecarCaptureClient(env, logger)
		: new BindingCaptureClient(env, logger);
}
