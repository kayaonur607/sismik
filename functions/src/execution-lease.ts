import { Firestore, Timestamp } from 'firebase-admin/firestore';

// Scheduler is at-least-once and old/new revisions can overlap on deploy.
// A durable lease bounds that overlap without allocating an always-on server.
//
// Dakikalık görev her turda bu kilidi alıp bırakıyor. İki transaction
// (oku+yaz, oku+sil) dakikada 2 okuma + 2 yazım ve dört ek RPC demekti.
// Artık kilit `create()` ile alınıyor (belge yoksa tek yazım, okuma yok) ve
// alınırkenki yazım zamanı ön koşuluyla siliniyor: süresi dolduktan sonra
// kilidi başka bir çağrı devraldıysa silme reddedilir, onun kilidi korunur.
export async function withExecutionLease(
  db: Firestore, name: string, durationMs: number, work: () => Promise<void>
): Promise<boolean> {
  const ref = db.collection('_system').doc(name);
  const acquiredAt = await acquireLease(ref, durationMs);
  if (!acquiredAt) return false;
  try {
    await work();
    return true;
  } finally {
    try {
      await ref.delete({ lastUpdateTime: acquiredAt });
    } catch (error: any) {
      // FAILED_PRECONDITION: kilit süresi dolup devralındı — dokunulmaz.
      if (!isGrpcCode(error, 9, 'FAILED_PRECONDITION') && !isGrpcCode(error, 5, 'NOT_FOUND')) {
        console.error('Scheduler lease release failed; it will expire:', error);
      }
    }
  }
}

async function acquireLease(
  ref: FirebaseFirestore.DocumentReference,
  durationMs: number
): Promise<Timestamp | null> {
  const lease = { expires_at: Date.now() + durationMs };
  try {
    return (await ref.create(lease)).writeTime;
  } catch (error: any) {
    if (!isGrpcCode(error, 6, 'ALREADY_EXISTS')) throw error;
  }

  // Nadir yol: önceki tur hâlâ sürüyor ya da kilidi bırakamadan çöktü.
  const snapshot = await ref.get();
  if (snapshot.exists && Number(snapshot.data()?.expires_at || 0) > Date.now()) return null;
  try {
    return snapshot.exists
      ? (await ref.update(lease, { lastUpdateTime: snapshot.updateTime! })).writeTime
      : (await ref.create(lease)).writeTime;
  } catch (error: any) {
    // Aynı anda başka bir çağrı devraldı.
    if (isGrpcCode(error, 9, 'FAILED_PRECONDITION') || isGrpcCode(error, 6, 'ALREADY_EXISTS')) return null;
    throw error;
  }
}

function isGrpcCode(error: any, code: number, name: string): boolean {
  return error?.code === code || error?.code === name;
}
