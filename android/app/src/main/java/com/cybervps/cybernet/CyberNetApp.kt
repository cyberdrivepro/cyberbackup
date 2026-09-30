package com.cybervps.cybernet

import android.app.Application
import com.cybervps.cybernet.security.KeystoreManager

class CyberNetApp : Application() {

    lateinit var keystore: KeystoreManager
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        keystore = KeystoreManager(this)
    }

    companion object {
        lateinit var instance: CyberNetApp
            private set
    }
}
