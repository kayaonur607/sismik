import {
  Environment,
  JWSTransactionDecodedPayload,
  ResponseBodyV2DecodedPayload,
  SignedDataVerifier
} from '@apple/app-store-server-library';
import { loadAppleRootCertificates } from './apple-root-certificates';

const BUNDLE_ID = 'com.kayasoftware.sismik';
const APP_APPLE_ID = 6787776158;
/// Tek seferlik ömür boyu satın alma (tüketilmeyen ürün): bitiş tarihi yok.
export const LIFETIME_PRODUCT_ID = 'com.kayasoftware.sismik.lifetime';
const PRODUCT_IDS = new Set([
  'com.kayasoftware.sismik.premium.monthly',
  'com.kayasoftware.sismik.premium.yearly',
  LIFETIME_PRODUCT_ID
]);

const roots = loadAppleRootCertificates();
const productionVerifier = new SignedDataVerifier(
  roots,
  true,
  Environment.PRODUCTION,
  BUNDLE_ID,
  APP_APPLE_ID
);
const sandboxVerifier = new SignedDataVerifier(
  roots,
  true,
  Environment.SANDBOX,
  BUNDLE_ID
);

export interface VerifiedSubscription {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  environment: string;
  purchaseDate: number;
  originalPurchaseDate: number;
  expiresDate: number;
  signedDate: number;
  appAccountToken?: string;
  isActive: boolean;
  status: 'active' | 'expired' | 'revoked';
}

export interface VerifiedServerNotification {
  payload: ResponseBodyV2DecodedPayload;
  environment: Environment;
}

async function verifyWithKnownEnvironment<T>(
  production: () => Promise<T>,
  sandbox: () => Promise<T>
): Promise<{ value: T; environment: Environment }> {
  try {
    return { value: await production(), environment: Environment.PRODUCTION };
  } catch (productionError) {
    try {
      return { value: await sandbox(), environment: Environment.SANDBOX };
    } catch {
      throw productionError;
    }
  }
}

export function normalizeVerifiedTransaction(
  transaction: JWSTransactionDecodedPayload,
  now: number = Date.now()
): VerifiedSubscription {
  const originalTransactionId = String(transaction.originalTransactionId || '');
  const transactionId = String(transaction.transactionId || '');
  const productId = String(transaction.productId || '');
  const expiresDate = Number(transaction.expiresDate || 0);
  const signedDate = Number(transaction.signedDate || 0);

  const isLifetime = productId === LIFETIME_PRODUCT_ID;
  // Abonelik bitiş tarihi taşımalı; ömür boyu ürünün bitişi yoktur (0).
  if (!originalTransactionId || !transactionId || !PRODUCT_IDS.has(productId)
      || (!isLifetime && !expiresDate) || !signedDate) {
    throw new Error('Verified transaction is missing required Sismik subscription fields');
  }

  const revoked = Number(transaction.revocationDate || 0) > 0;
  // İade edilen ömür boyu satın alma `revocationDate` ile gelir.
  const isActive = !revoked && (isLifetime || expiresDate > now);

  return {
    originalTransactionId,
    transactionId,
    productId,
    environment: String(transaction.environment || ''),
    purchaseDate: Number(transaction.purchaseDate || 0),
    originalPurchaseDate: Number(transaction.originalPurchaseDate || transaction.purchaseDate || 0),
    expiresDate: isLifetime ? 0 : expiresDate,
    signedDate,
    ...(transaction.appAccountToken ? { appAccountToken: transaction.appAccountToken } : {}),
    isActive,
    status: revoked ? 'revoked' : isActive ? 'active' : 'expired'
  };
}

export async function verifyTransactionJWS(signedTransaction: string): Promise<VerifiedSubscription> {
  const compactJWS = signedTransaction.trim();
  if (!compactJWS || compactJWS.length > 32_000) {
    throw new Error('Invalid signed transaction size');
  }

  const verified = await verifyWithKnownEnvironment(
    () => productionVerifier.verifyAndDecodeTransaction(compactJWS),
    () => sandboxVerifier.verifyAndDecodeTransaction(compactJWS)
  );
  return normalizeVerifiedTransaction(verified.value);
}

export async function verifyServerNotification(signedPayload: string): Promise<VerifiedServerNotification> {
  const compactJWS = signedPayload.trim();
  if (!compactJWS || compactJWS.length > 128_000) {
    throw new Error('Invalid signed notification size');
  }

  const verified = await verifyWithKnownEnvironment(
    () => productionVerifier.verifyAndDecodeNotification(compactJWS),
    () => sandboxVerifier.verifyAndDecodeNotification(compactJWS)
  );
  return { payload: verified.value, environment: verified.environment };
}
