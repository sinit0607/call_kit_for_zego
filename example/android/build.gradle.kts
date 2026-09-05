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
// zego_express_engine 3.25.0 still declares compileSdkVersion 31, but its own
// AndroidX dependencies require 33+, which fails the build for every app that
// depends on it. Raise the compileSdk of any plugin that is behind the app's.
// Remove once ZEGOCLOUD ships a build with a current compileSdk.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val android = ext as com.android.build.gradle.BaseExtension
            if (android.compileSdkVersion?.substringAfter("android-")?.toIntOrNull()
                    ?.let { it < 35 } == true) {
                android.compileSdkVersion(35)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
