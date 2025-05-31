import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea", "form"]

  keydown(event) {
    if (event.key === "Enter") {
      if (event.shiftKey) {
        return
      } else {
        event.preventDefault()
        this.submitForm()
      }
    }
  }

  submitForm() {
    const form = this.textareaTarget.closest("form")
    if (form) {
      form.requestSubmit()
    }
  }

  clearForm() {
    this.textareaTarget.value = ""
  }
}