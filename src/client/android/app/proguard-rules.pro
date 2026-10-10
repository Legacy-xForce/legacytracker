# Credential Manager (passkeys) loads its Play Services provider by
# reflection; keep it from being stripped in release builds.
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}
