# Credential Manager (passkeys) loads its Play Services provider by
# reflection; keep it from being stripped in release builds.
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}

# WorkManager's Room database is instantiated reflectively through its
# generated no-arg constructor; R8 otherwise strips it and the app dies in
# androidx.startup before Flutter starts.
-keep class * extends androidx.room.RoomDatabase {
  <init>();
}
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
