import * as fs from 'fs';
import * as path from 'path';

/**
 * Apple imzalı StoreKit JWS verisini doğrulamak için gereken, Apple PKI
 * sayfasından alınmış DER kök sertifikaları. Dosyalar deploy paketine
 * `functions/certs` altında dahil edilir.
 */
export function loadAppleRootCertificates(): Buffer[] {
  const certDirectory = path.join(__dirname, '..', 'certs');
  return [
    'AppleIncRootCertificate.cer',
    'AppleRootCA-G2.cer',
    'AppleRootCA-G3.cer'
  ].map(file => fs.readFileSync(path.join(certDirectory, file)));
}
