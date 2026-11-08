package com.iaportafolio.argos.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Modelo `Server`: compatibilidad con el `servers.json` que escribe Apple. */
class ServerTest {

    @Test
    fun `endpoint es host y puerto`() {
        assertEquals("dev.example.com:2222", Server(name = "dev", host = "dev.example.com", port = 2222, username = "u").endpoint)
    }

    @Test
    fun `json antiguo sin authMethod asume clave y valores por defecto`() {
        val json = """[{"id":"6F1C2A3B-0000-4000-8000-000000000001","name":"dev","host":"h","port":22,"username":"u"}]"""
        val server = Server.JSON.decodeFromString<List<Server>>(json).single()
        assertEquals(AuthMethod.KEY, server.authMethod)
        assertEquals("", server.privateKeyPath)
        assertEquals(false, server.requiresPassphrase)
        assertEquals("6F1C2A3B-0000-4000-8000-000000000001", server.id)
    }

    @Test
    fun `json de Apple con bookmark y contrasena se decodifica ignorando el bookmark`() {
        val json = """{"id":"A","name":"p","host":"h","port":22,"username":"u","authMethod":"password",""" +
            """"privateKeyPath":"~/.ssh/id","privateKeyBookmark":"Ym9va21hcms=","requiresPassphrase":true}"""
        val server = Server.JSON.decodeFromString<Server>(json)
        assertEquals(AuthMethod.PASSWORD, server.authMethod)
        assertEquals("~/.ssh/id", server.privateKeyPath)
        assertTrue(server.requiresPassphrase)
    }

    @Test
    fun `codificar y decodificar conserva el servidor con las claves de Apple`() {
        val server = Server(name = "dev", host = "h", username = "u")
        val json = Server.JSON.encodeToString(Server.serializer(), server)
        assertTrue("\"authMethod\":\"key\"" in json)
        assertTrue("\"port\":22" in json)
        assertEquals(server, Server.JSON.decodeFromString<Server>(json))
    }

    @Test
    fun `los ids nuevos son UUID en mayusculas como en Apple`() {
        val id = Server.newId()
        assertEquals(id.uppercase(), id)
        assertEquals(36, id.length)
    }

    @Test
    fun `userMessage usa el mensaje del error tipado`() {
        assertEquals("tmux no está instalado en el servidor.", SSHServiceError.TmuxNotInstalled().userMessage)
        assertEquals("IllegalStateException", IllegalStateException().userMessage)
    }
}
