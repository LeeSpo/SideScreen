pluginManagement {
    repositories {
        mavenCentral()
        // Google Maven's primary hostname is unreachable on this build host.
        maven("https://maven.aliyun.com/repository/google")
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
        maven("https://maven.aliyun.com/repository/google")
    }
}

rootProject.name = "SideScreen"
include(":app")
