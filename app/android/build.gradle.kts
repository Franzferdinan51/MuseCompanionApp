allprojects {
    repositories {
        google()
        mavenCentral()
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

// 2026-10-04: receive_sharing_intent 1.8.1 doesn't set a JVM target.
// Flutter's Gradle plugin sets its Kotlin to 17 (from the app's config)
// while its Java stays at 8, causing "Inconsistent JVM Target Compatibility".
// Align its Java to 17. (Pinned to 1.8.1 because 1.9.0's build.gradle uses
// the Kotlin 2.x DSL without applying the plugin.)
subprojects {
    if (project.name == "receive_sharing_intent") {
        pluginManager.withPlugin("com.android.library") {
            extensions.findByType(
                com.android.build.gradle.LibraryExtension::class.java
            )?.let { ext ->
                ext.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                ext.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// 2026-10-08: tflite_flutter (develop branch) has the same missing-JVM-target
// issue as receive_sharing_intent. Align its Java to 17.
subprojects {
    if (project.name == "tflite_flutter") {
        pluginManager.withPlugin("com.android.library") {
            extensions.findByType(
                com.android.build.gradle.LibraryExtension::class.java
            )?.let { ext ->
                ext.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                ext.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
}
