import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["output", "viewToggle", "diffSelect", "shadowContent"]
  static values = {
    uncommittedDiff: String,
    targetBranchDiff: String,
    hasTargetBranch: Boolean
  }

  connect() {
    this.outputFormat = 'side-by-side'
    this.currentDiffType = 'uncommitted'
    // Ensure the shadow root is available
    this.ensureShadowRoot()
    
    // If there's only a target branch diff and no uncommitted diff, switch to target branch view
    if (this.hasTargetBranchValue && this.targetBranchDiffValue && !this.uncommittedDiffValue.trim()) {
      this.currentDiffType = 'target-branch'
      if (this.hasDiffSelectTarget) {
        this.diffSelectTarget.value = 'target-branch'
      }
    }
    
    // Render if we have any diff
    if ((this.hasUncommittedDiffValue && this.uncommittedDiffValue.trim()) ||
        (this.hasTargetBranchValue && this.targetBranchDiffValue.trim())) {
      this.render()
    }
  }

  switchDiff(event) {
    this.currentDiffType = event.target.value
    this.render()
  }

  toggleView() {
    this.outputFormat = this.viewToggleTarget.checked ? 'side-by-side' : 'line-by-line'
    this.render()
  }

  ensureShadowRoot() {
    // Check if shadow root already exists
    if (this.outputTarget.shadowRoot) {
      return this.outputTarget.shadowRoot
    }

    // If there's a template with shadowrootmode, the browser should have already created the shadow root
    // But in case it hasn't (e.g., due to timing issues with Turbo), we'll create it manually
    const template = this.outputTarget.querySelector('template[shadowrootmode]')
    if (template && !this.outputTarget.shadowRoot) {
      const shadowRoot = this.outputTarget.attachShadow({ mode: 'open' })
      shadowRoot.appendChild(template.content.cloneNode(true))
      return shadowRoot
    }

    return this.outputTarget.shadowRoot
  }

  render() {
    if (typeof Diff2HtmlUI === 'undefined') {
      console.error('Diff2HtmlUI is not available')
      return
    }

    // Ensure shadow root exists
    const shadowRoot = this.ensureShadowRoot()
    if (!shadowRoot) {
      console.error('Shadow root not found and could not be created')
      return
    }

    // Find the content container in the shadow DOM
    const contentContainer = shadowRoot.querySelector('[data-diff-target="shadowContent"]')
    if (!contentContainer) {
      console.error('Shadow content container not found')
      return
    }

    // Get the appropriate diff text based on current selection
    let diffText = ''
    if (this.currentDiffType === 'target-branch' && this.hasTargetBranchDiffValue) {
      diffText = this.targetBranchDiffValue
    } else if (this.hasUncommittedDiffValue) {
      diffText = this.uncommittedDiffValue
    }

    // Create Diff2HtmlUI instance targeting the shadow DOM container
    const diff2htmlUi = new Diff2HtmlUI(contentContainer, diffText, {
      drawFileList: true,
      fileListToggle: true,
      fileListStartVisible: false,
      fileContentToggle: true,
      matching: 'lines',
      outputFormat: this.outputFormat,
      synchronisedScroll: true,
      renderNothingWhenEmpty: false,
      highlight: true,
      fileListCloseable: false,
      colorScheme: 'auto'
    })
    
    diff2htmlUi.draw()
  }
}