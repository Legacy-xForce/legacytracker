allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Apply Kotlin plugin to all subprojects (required by mapbox_maps_flutter)
subprojects {
    plugins.withId("com.android.library") {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
