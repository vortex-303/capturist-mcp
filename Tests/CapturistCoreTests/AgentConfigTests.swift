import Testing
@testable import CapturistCore

@Suite struct AgentConfigTests {
    let entry: [String: Any] = ["command": "/bin/capturist", "args": ["mcp"]]

    @Test func addsToEmptyConfig() throws {
        let out = try AgentConfig.setJSON([:], path: ["mcpServers"], name: "capturist", entry: entry)
        #expect(AgentConfig.hasJSON(out, path: ["mcpServers"], name: "capturist"))
    }

    @Test func keepsOtherKeysAndServers() throws {
        let config: [String: Any] = ["theme": "dark", "servers": ["Neon": ["url": "x"]]]
        let out = try AgentConfig.setJSON(config, path: ["servers"], name: "capturist", entry: entry)
        #expect(out["theme"] as? String == "dark")
        #expect(AgentConfig.hasJSON(out, path: ["servers"], name: "Neon"))
        #expect(AgentConfig.hasJSON(out, path: ["servers"], name: "capturist"))
    }

    @Test func removes() throws {
        let added = try AgentConfig.setJSON(["mcp": ["a": 1]], path: ["mcp"], name: "capturist", entry: entry)
        let out = try AgentConfig.setJSON(added, path: ["mcp"], name: "capturist", entry: nil)
        #expect(!AgentConfig.hasJSON(out, path: ["mcp"], name: "capturist"))
        #expect(AgentConfig.hasJSON(out, path: ["mcp"], name: "a"))
    }

    @Test func removeFromMissingIsNoop() throws {
        let out = try AgentConfig.setJSON(["x": 1], path: ["mcpServers"], name: "capturist", entry: nil)
        #expect(out["mcpServers"] == nil)
    }

    @Test func nestedPath() throws {
        let out = try AgentConfig.setJSON([:], path: ["mcp", "servers"], name: "capturist", entry: entry)
        #expect(AgentConfig.hasJSON(out, path: ["mcp", "servers"], name: "capturist"))
    }

    @Test func refusesNonObject() {
        #expect(throws: AgentConfig.ConfigError.notAnObject("mcpServers")) {
            try AgentConfig.setJSON(["mcpServers": [1, 2]], path: ["mcpServers"], name: "capturist", entry: entry)
        }
    }

    // MARK: YAML

    let fields = ["command: \"/bin/capturist\"", "args: [\"mcp\"]", "enabled: true"]

    @Test func yamlAppendsSection() throws {
        let out = try AgentConfig.setYAML("model: x\n", section: "mcp_servers", name: "capturist", fields: fields)
        #expect(out == "model: x\nmcp_servers:\n  capturist:\n    command: \"/bin/capturist\"\n    args: [\"mcp\"]\n    enabled: true\n")
        #expect(AgentConfig.hasYAML(out, section: "mcp_servers", name: "capturist"))
    }

    @Test func yamlInsertsIntoExistingSection() throws {
        let text = "mcp_servers:\n  notes:\n    command: node\n    enabled: true\nupdate:\n  channel: stable\n"
        let out = try AgentConfig.setYAML(text, section: "mcp_servers", name: "capturist", fields: fields)
        #expect(out == "mcp_servers:\n  notes:\n    command: node\n    enabled: true\n  capturist:\n    command: \"/bin/capturist\"\n    args: [\"mcp\"]\n    enabled: true\nupdate:\n  channel: stable\n")
    }

    @Test func yamlReplacesAndRemoves() throws {
        let text = "mcp_servers:\n  capturist:\n    command: /old\n    args:\n      - mcp\n    enabled: true\n  notes:\n    command: node\nupdate: {}\n"
        let replaced = try AgentConfig.setYAML(text, section: "mcp_servers", name: "capturist", fields: fields)
        #expect(!replaced.contains("/old"))
        #expect(replaced.contains("  notes:\n    command: node\n  capturist:\n    command: \"/bin/capturist\""))
        let removed = try AgentConfig.setYAML(replaced, section: "mcp_servers", name: "capturist", fields: nil)
        #expect(removed == "mcp_servers:\n  notes:\n    command: node\nupdate: {}\n")
        #expect(!AgentConfig.hasYAML(removed, section: "mcp_servers", name: "capturist"))
    }

    @Test func yamlEmptyFlowMapping() throws {
        let out = try AgentConfig.setYAML("mcp_servers: {}\n", section: "mcp_servers", name: "capturist", fields: fields)
        #expect(out.hasPrefix("mcp_servers:\n  capturist:\n"))
    }

    @Test func yamlRefusesFlowStyle() {
        #expect(throws: AgentConfig.ConfigError.self) {
            try AgentConfig.setYAML("mcp_servers: {a: {command: x}}\n", section: "mcp_servers", name: "capturist", fields: self.fields)
        }
    }
}
