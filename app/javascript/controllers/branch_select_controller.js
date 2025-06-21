import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "loading"]
  static values = { projectId: Number }
  static classes = ["hidden"]
  
  connect() {
    // Set a default value immediately
    this.setDefaultBranch()
    this.loadBranches()
  }
  
  setDefaultBranch() {
    this.selectTarget.innerHTML = ""
    const option = document.createElement("option")
    option.value = ""
    option.text = "*default*"
    option.selected = true
    this.selectTarget.appendChild(option)
    this.selectTarget.disabled = false
  }
  
  async loadBranches() {
    if (!this.projectIdValue) return
    
    this.showLoading()
    
    try {
      const response = await fetch(`/projects/${this.projectIdValue}/project_branches`)
      const data = await response.json()
      
      if (response.ok) {
        this.populateSelect(data.branches, data.default_branch)
      } else {
        console.error("Failed to load branches:", data.error)
        this.hideLoading()
      }
    } catch (error) {
      console.error("Error loading branches:", error)
      this.hideLoading()
    }
  }
  
  populateSelect(branches, defaultBranch) {
    this.selectTarget.innerHTML = ""
    
    if (branches.length === 0) {
      const option = document.createElement("option")
      option.value = ""
      option.text = defaultBranch || "*default*"
      this.selectTarget.appendChild(option)
    } else {
      // Add the default branch as the first option
      if (defaultBranch) {
        const defaultOption = document.createElement("option")
        defaultOption.value = defaultBranch
        defaultOption.text = defaultBranch
        defaultOption.selected = true
        this.selectTarget.appendChild(defaultOption)
      }
      
      // Add other branches, avoiding duplicates
      branches.forEach(branch => {
        if (branch !== defaultBranch) {
          const option = document.createElement("option")
          option.value = branch
          option.text = branch
          this.selectTarget.appendChild(option)
        }
      })
    }
    
    this.selectTarget.disabled = false
    this.hideLoading()
  }
  
  showLoading() {
    if (this.hasLoadingTarget && this.hasHiddenClass) {
      this.loadingTarget.classList.remove(this.hiddenClass)
    }
  }
  
  hideLoading() {
    if (this.hasLoadingTarget && this.hasHiddenClass) {
      this.loadingTarget.classList.add(this.hiddenClass)
    }
  }
}