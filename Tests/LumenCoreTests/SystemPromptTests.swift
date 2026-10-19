import Foundation
import Testing
@testable import LumenCore

@Suite struct SystemPromptTests {
    private let readTools = ["list_files", "read_file", "search_files"]

    @Test func placeholderIsReplacedEvenWithNoTools() {
        let rendered = SystemPrompt.render("Before\n\(SystemPrompt.placeholder)\nAfter", tools: [])
        #expect(!rendered.contains(SystemPrompt.placeholder))
        #expect(rendered == "Before\n\nAfter")
    }

    @Test func guidanceAppearsOnlyForAdvertisedTools() {
        let readOnly = SystemPrompt.render(SystemPrompt.placeholder, tools: readTools)
        #expect(readOnly.contains("list_files"))
        #expect(!readOnly.contains("edit_file"))
        #expect(!readOnly.contains("run_command"))
        // Tool guidance never mentions an approval requirement that does not apply.
        #expect(!readOnly.contains("require explicit approval"))

        let all = SystemPrompt.render(SystemPrompt.placeholder, tools: readTools + ["edit_file", "run_command"])
        #expect(all.contains("edit_file"))
        #expect(all.contains("run_command"))
        #expect(all.contains("require explicit approval"))
        // Tools Lumen does not have must never be described as callable.
        #expect(!all.contains("write tool"))
        #expect(!all.contains("patch"))
        #expect(!all.contains("subagent"))
        #expect(!all.contains("oldString"))
        #expect(!all.contains("replaceAll"))
    }

    @Test func basePromptKeepsWorkingInAProjectRulesForSmallToolSets() {
        // The behavioral rules live in the template itself, not in tool guidance, so
        // they survive a request that advertises no tools.
        let rendered = SystemPrompt.render(SystemPrompt.base, tools: [])
        #expect(rendered.contains("Working in a project"))
        #expect(rendered.contains("untrusted data"))
        #expect(!rendered.contains(SystemPrompt.placeholder))
    }

    @Test func gptModelsReplaceTheBasePrompt() {
        let system = SystemPrompt.system(agentPrompt: "", tools: readTools, modelID: "gpt-5-codex", instructions: [])
        #expect(system.hasPrefix("You are Lumen, a coding agent running in a native macOS app."))
        #expect(system.contains("Destructive actions"))
        // Not the default base prompt.
        #expect(!system.contains("practical, careful assistant"))
    }

    @Test func claudeModelsAppendCodeCommentGuidance() {
        let base = SystemPrompt.system(agentPrompt: "", tools: [], modelID: "claude-sonnet-4-5", instructions: [])
        #expect(base.hasPrefix("You are Lumen, a practical, careful assistant"))
        #expect(base.contains("# Code comments"))
        let other = SystemPrompt.system(agentPrompt: "", tools: [], modelID: "llama-3.1-70b", instructions: [])
        #expect(!other.contains("# Code comments"))
        #expect(other.hasPrefix("You are Lumen, a practical, careful assistant"))
    }

    @Test func customPromptReplacesBaseAndSuppressesProviderOverrides() {
        let custom = "Always answer in haiku."
        for model in ["gpt-5", "claude-opus-4", "llama-3.1-70b"] {
            let system = SystemPrompt.system(agentPrompt: custom, tools: readTools, modelID: model, instructions: [])
            #expect(system.hasPrefix(custom))
            #expect(!system.contains("You are Lumen"))
            #expect(!system.contains("# Code comments"))
        }
    }

    @Test func savedDefaultIsTreatedAsNotCustomized() {
        // A config holding the current default still gets tool guidance and the
        // provider override, because the default is a template, not a custom prompt.
        let system = SystemPrompt.system(agentPrompt: SystemPrompt.base, tools: readTools, modelID: "gpt-5", instructions: [])
        #expect(system.contains("coding agent running in a native macOS app"))
        #expect(system.contains("list_files"))
    }

    @Test func mcpToolsCountAsAdvertisedTools() {
        // MCP tools are not in Lumen's native list, so they must not invent guidance,
        // but they also must not remove guidance for the native tools present.
        let rendered = SystemPrompt.render(SystemPrompt.base, tools: ["read_file", "mcp__git__status"])
        #expect(rendered.contains("list_files"))
        #expect(!rendered.contains("require explicit approval"))
        // MCP tools run under the server's own permissions, so the approve rule is
        // stated only by the edit_file/run_command guidance above.
        #expect(!SystemPrompt.render(SystemPrompt.placeholder, tools: ["mcp__git__status"]).contains("approval"))
    }

    @Test func instructionsFollowTheFirstPart() {
        let instructions = [InstructionSource(key: "core/date", text: "Today's date: 2026-02-03")]
        let system = SystemPrompt.system(agentPrompt: "Custom.", tools: [], modelID: "gpt-5", instructions: instructions)
        #expect(system == "Custom.\n\nToday's date: 2026-02-03")
        #expect(SystemPrompt.system(agentPrompt: "Custom.", tools: [], modelID: "gpt-5", instructions: []).hasSuffix("Custom."))
    }

    @Test func maxStepsPromptForbidsTools() {
        #expect(SystemPrompt.maxSteps.contains("MAXIMUM STEPS REACHED"))
        #expect(SystemPrompt.maxSteps.contains("Respond with text only"))
    }
}
