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

# shared_preferences_android 2.5+ binds its Kotlin classes over JNI by name
# and signature (Continuation, CoroutineSingletons, Result, Unit...). R8
# otherwise renames or strips them, every SharedPreferences call throws, and
# the app sits on its startup spinner. Keep the stdlib it reaches into.
-keep class kotlin.** {
  *;
}
