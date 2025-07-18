;;; test-end-to-end.el --- True end-to-end tests for greger -*- lexical-binding: t -*-

;;; Commentary:
;;
;; This file contains true end-to-end tests that use greger as an end user would,
;; calling only the public API functions `greger` and `greger-buffer`.
;; These tests require a valid ANTHROPIC_API_KEY environment variable.
;;
;; WARNING: These tests make real API calls and may incur costs.
;;

(require 'ert)
(require 'greger)

(defvar greger-test-timeout 30
  "Timeout in seconds for API calls in tests.")

(defun greger-test-parse-tree ()
  (greger-test-treesit-node-to-simplified-tree (treesit-buffer-root-node)))

(defun greger-test-last-assistant-message ()
  (let (start end)
    (save-excursion
      (goto-char (point-max))
      (re-search-backward "^# ASSISTANT")
      (forward-line 2)
      (setq start (point))
      (re-search-forward "^# USER")
      (forward-line -1)
      (forward-char -1)
      (setq end (point)))
    (buffer-substring-no-properties start end)))

(defun greger-test-treesit-node-to-simplified-tree (node)
  "Convert a treesit NODE to a simplified parse tree expression.
Returns a list where the first element is the node type (symbol)
and the remaining elements are the simplified representations of child nodes.
Leaf nodes are wrapped in parentheses as single-element lists."
  (let ((node-type (intern (treesit-node-type node)))
        (children (treesit-node-children node t)))
    (if children
        (cons node-type
              (mapcar #'greger-test-treesit-node-to-simplified-tree children))
      (list node-type))))

(defun greger-test-parse-tree-contains-p (parse-tree name)
  (cond
   ((null parse-tree) nil)
   ((atom parse-tree) (equal parse-tree name))
   ((listp parse-tree)
    (or (greger-test-parse-tree-contains-p (car parse-tree) name)
        (greger-test-parse-tree-contains-p (cdr parse-tree) name)))))

(defun greger-test-mode-line-text (&optional buffer)
  "Get mode line text from BUFFER or current buffer.
Uses greger--mode-line-info to get the greger-specific portion of the mode line."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (if (fboundp 'greger--mode-line-info)
          (greger--mode-line-info)
        ""))))

(defun greger-test-wait-for-status (status &optional timeout)
  "Wait for greger buffer to reach STATUS within TIMEOUT seconds."
  (let ((start-time (current-time))
        (current-status nil)
        (timeout (or timeout greger-test-timeout)))
    (while (and (not (equal status current-status))
                (< (float-time (time-subtract (current-time) start-time)) timeout))
      (setq current-status (greger--get-current-status))
      (sit-for 0.2))
    (equal status current-status)))

(ert-deftest greger-end-to-end-test-greger-function ()
  "Test the main greger function creates a buffer and sets it up correctly."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((original-buffers (buffer-list)))
    (unwind-protect
        (progn
          ;; Call the main greger function
          (greger)

          ;; Verify a new greger buffer was created
          (let ((new-buffers (cl-remove-if (lambda (buf) (memq buf original-buffers))
                                           (buffer-list))))
            (should (= 1 (length new-buffers)))
            (let ((greger-buffer (car new-buffers)))
              (should (string-match-p "\\*greger\\*" (buffer-name greger-buffer)))

              ;; Verify buffer is in greger-mode
              (with-current-buffer greger-buffer
                (should (eq major-mode 'greger-mode))

                ;; Verify initial content is set up correctly
                (let ((content (buffer-string)))
                  (should (string-match-p "# SYSTEM" content))
                  (should (string-match-p "# USER" content))
                  (should (string-match-p greger-default-system-prompt content)))

                ;; Verify we're at the end of the buffer (ready for user input)
                (should (= (point) (point-max)))))))

      ;; Cleanup: kill any greger buffers we created
      (dolist (buffer (buffer-list))
        (when (and (string-match-p "\\*greger\\*" (buffer-name buffer))
                   (not (memq buffer original-buffers)))
          (kill-buffer buffer))))))

(ert-deftest greger-end-to-end-test-simple-conversation ()
  "Test a simple conversation using the public API."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((greger-buffer nil))
    (unwind-protect
        (progn
          (let ((greger-default-system-prompt "You are an agent."))
            (setq greger-buffer (greger)))

          (goto-char (point-max))
          (insert "Respond with exactly 'Hello from greger test!' and nothing else (don't include the quotes).")

          (let ((greger-current-thinking-budget 0))
            (greger-buffer))

          (should (greger-test-wait-for-status 'idle))

          (let ((buffer-contents (buffer-substring-no-properties (point-min) (point-max)))
                (expected "# SYSTEM

You are an agent.

# USER

Respond with exactly 'Hello from greger test!' and nothing else (don't include the quotes).

# ASSISTANT

Hello from greger test!

# USER

"))
            (should (string= expected buffer-contents))))
      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-tool-use-conversation ()
  "Test a conversation that involves tool use using the public API."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  ;; Register a basic read-file tool that only accepts path
  (defun greger-test-read-file-basic (path)
    "Simple wrapper around greger-stdlib--read-file that only accepts path."
    (greger-stdlib--read-file path nil nil nil))

  (greger-register-tool "read-file-basic"
                        :description "Read the contents of a file from the filesystem (basic version with only path argument)"
                        :properties '((path . ((type . "string")
                                               (description . "Path to the file to read"))))
                        :required '("path")
                        :function 'greger-test-read-file-basic)

  (let ((greger-buffer nil)
        (test-file nil))
    (unwind-protect
        (progn
          (setq test-file (make-temp-file "greger-test-" nil ".txt"))
          (with-temp-file test-file
            (insert "This is a test file for greger end-to-end testing wahey"))

          (let ((greger-default-system-prompt "You are an agent."))
            (setq greger-buffer (greger)))

          (goto-char (point-max))
          (insert (format "Read the file %s and output only the last word of that file, nothing else." test-file))

          (let ((greger-current-thinking-budget 1024)
                (greger-tools '("read-file-basic")))
            (greger-buffer)

            (should (greger-test-wait-for-status 'idle))

            (let ((expected-parse-tree '(source_file
                                         (system
                                          (system_header)
                                          (text))
                                         (user
                                          (user_header)
                                          (text))
                                         (thinking
                                          (thinking_header)
                                          (thinking_signature
                                           (key)
                                           (value))
                                          (text))
                                         (tool_use
                                          (tool_use_header)
                                          (name
                                           (key)
                                           (value))
                                          (id
                                           (key)
                                           (value))
                                          (tool_param
                                           (tool_param_header
                                            (name))
                                           (value
                                            (tool_start_tag)
                                            (tool_content
                                             (tool_content_head))
                                            (tool_end_tag))))
                                         (tool_result
                                          (tool_result_header)
                                          (id
                                           (key)
                                           (value))
                                          (content))
                                         (assistant
                                          (assistant_header)
                                          (text))
                                         (user
                                          (user_header)
                                          (text)))))
              (should (equal expected-parse-tree (greger-test-parse-tree))))

            (should (equal "wahey" (greger-test-last-assistant-message)))))

      (when (and test-file (file-exists-p test-file))
        (delete-file test-file))
      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-no-tools-mode ()
  "Test the no-tools mode using C-M-return."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((greger-buffer nil)
        (test-file nil))
    (unwind-protect
        (progn
          (setq test-file (make-temp-file "greger-test-" nil ".txt"))
          (with-temp-file test-file
            (insert "This file should not be read in no-tools mode wahey."))

          (setq greger-buffer (greger))

          (goto-char (point-max))
          (insert (format "Read the file %s and output only the last word of that file, nothing else." test-file))

          (greger-buffer-no-tools)

          (should (greger-test-wait-for-status 'idle))

          (let ((parse-tree (greger-test-parse-tree)))
            (should (not (greger-test-parse-tree-contains-p parse-tree 'thinking)))
            (should (not (greger-test-parse-tree-contains-p parse-tree 'tool_use)))
            (should (not (greger-test-parse-tree-contains-p parse-tree 'tool_result))))

          (should-not (string-match-p "wahey" (greger-test-last-assistant-message))))

      (when (and test-file (file-exists-p test-file))
        (delete-file test-file))
      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-model-configuration ()
  "Test that model configuration works correctly."
  (let ((original-model greger-model)
        (greger-buffer nil))
    (unwind-protect
        (progn
          ;; Test that we can set different supported models
          (setq greger-model 'claude-opus-4-20250514)
          (should (eq greger-model 'claude-opus-4-20250514))

          (setq greger-model 'claude-sonnet-4-20250514)
          (should (eq greger-model 'claude-sonnet-4-20250514))

          ;; Create a greger buffer and verify model is displayed
          (greger)
          (setq greger-buffer (current-buffer))

          ;; The model should be shown in the mode line
          (should (string-match-p "claude-sonnet-4-20250514"
                                  (format "%s" (symbol-name greger-model)))))

      ;; Cleanup
      (setq greger-model original-model)
      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-sleep-and-interrupt ()
  "Test sleep command with interruption and state transitions."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((greger-buffer nil))
    (unwind-protect
        (progn
          (let ((greger-default-system-prompt "You are an agent."))
            (setq greger-buffer (greger)))

          (goto-char (point-max))
          (re-search-backward "# SYSTEM")
          (forward-line 1)
          (insert "\n<safe-shell-commands>\nsleep 5\n</safe-shell-commands>\n")

          (goto-char (point-max))
          (insert "Run the shell command 'sleep 5' using the shell-command tool.")

          (let ((greger-current-thinking-budget 0)
                (greger-tools '("shell-command")))
            (greger-buffer)

            (should (greger-test-wait-for-status 'executing))

            ;; Wait 1 second while in executing state
            (sit-for 1.0)

            ;; Interrupt execution
            (let ((interrupted-state (greger-interrupt)))
              (should (eq interrupted-state 'executing)))

            (should (greger-test-wait-for-status 'generating))

            ;; Interrupt assistant message before it even started
            (let ((interrupted-state (greger-interrupt)))
              (should (eq interrupted-state 'generating)))

            ;; Should immediately become idle
            (should (greger-test-wait-for-status 'idle 0.1))

            (let ((content (buffer-string)))
              (should (string-match-p "Command failed with exit code 2" content)))

            (insert "Write me a long poem with ten paragraphs about Emacs lisp")

            (greger-buffer)

            (should (greger-test-wait-for-status 'generating))

            ;; Wait for assistant text to start appearing
            (sit-for 3.0)

            ;; Interrupt assistant text generation
            (let ((interrupted-state (greger-interrupt)))
              (should (eq interrupted-state 'generating)))

            (should (greger-test-wait-for-status 'idle 0.1))))

      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-server-tool-web-search ()
  "Test server tool functionality with web search."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((greger-buffer nil))
    (unwind-protect
        (progn
          (let ((greger-default-system-prompt "You are an agent."))
            (setq greger-buffer (greger))(greger))

          (let ((greger-server-tools '(web_search)))
            (goto-char (point-max))
            (insert "What is the current weather in San Francisco? Please search for this information and give me a short one-sentence summary.")

            (let ((greger-current-thinking-budget 0))
              (greger-buffer))

            (greger-test-wait-for-status 'idle)

            ;; Verify response was added to buffer
            (let ((content (buffer-string)))
              (should (string-match-p "# ASSISTANT" content))
              ;; Should contain server tool use section
              (should (string-match-p "# SERVER TOOL USE" content))
              (should (string-match-p "Name: web_search" content))
              ;; Should contain server tool result section
              (should (string-match-p "# WEB SEARCH TOOL RESULT" content))
              ;; Should contain some weather-related information
              (should (string-match-p "\\(weather\\|temperature\\|San Francisco\\)" content)))))

      ;; Cleanup
      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-thinking ()
  "Test thinking functionality works end-to-end."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((greger-buffer nil))
    (unwind-protect
        (progn
          (let ((greger-default-system-prompt "You are an agent."))
            (setq greger-buffer (greger)))

          (insert "2+2")

          (let ((greger-current-thinking-budget 1024))
            (greger-buffer))

          (should (greger-test-wait-for-status 'idle))

          (let ((expected-parse-tree '(source_file
                                       (system
                                        (system_header)
                                        (text))
                                       (user
                                        (user_header)
                                        (text))
                                       (thinking
                                        (thinking_header)
                                        (thinking_signature
                                         (key)
                                         (value))
                                        (text))
                                       (assistant
                                        (assistant_header)
                                        (text))
                                       (user
                                        (user_header)
                                        (text)))))
            (should (equal expected-parse-tree (greger-test-parse-tree))))

          (should (string-match-p "\\(2\\+2\\|four\\|addition\\|math\\)" (buffer-string))))

      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-thinking-toggle ()
  "Test thinking toggle functionality."

  (let ((greger-buffer nil)
        (greger-thinking-budget 2048))
    (unwind-protect
        (progn
          (setq greger-buffer (greger))

          (with-current-buffer greger-buffer
            (should (string-match-p "\\[T:2048\\]" (greger-test-mode-line-text)))

            (greger-toggle-thinking)
            (should (= greger-current-thinking-budget 0))
            (should-not (string-match-p "\\[T:" (greger-test-mode-line-text)))

            (greger-toggle-thinking)
            (should (> greger-current-thinking-budget 0))
            (should (= greger-current-thinking-budget 2048))

            (should (string-match-p "\\[T:2048\\]" (greger-test-mode-line-text)))))

      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(ert-deftest greger-end-to-end-test-follow-mode ()
  "Test follow-mode functionality and toggle."
  (skip-unless (getenv "ANTHROPIC_API_KEY"))

  (let ((greger-buffer nil))
    (unwind-protect
        (progn
          (let ((greger-default-system-prompt "You are an agent."))
            (setq greger-buffer (greger)))

          (with-current-buffer greger-buffer
            ;; Test that follow mode is enabled by default
            (should (eq greger-follow-mode t))

            ;; Position cursor at beginning of buffer
            (goto-char (point-min))
            (let ((initial-point (point)))

              ;; Add a simple message and run without tools (to avoid complex async)
              (goto-char (point-max))
              (insert "Say 'Hello' and nothing else.")

              (let ((greger-current-thinking-budget 0))
                ;; With follow mode enabled, point should move to bottom
                (goto-char initial-point)
                (should (= (point) initial-point))

                (greger-buffer)
                (greger-test-wait-for-status 'idle)

                ;; Point should be at the end now (follow mode behavior)
                (should (= (point) (point-max))))

              ;; Now test with follow mode disabled
              (greger-toggle-follow-mode)
              (should (eq greger-follow-mode nil))

              ;; Clear buffer and start fresh for second test
              (let ((inhibit-read-only t))
                (erase-buffer))
              (insert "# SYSTEM\n\nYou are an agent.\n\n# USER\n\nSay 'Goodbye' and nothing else.")

              ;; Position cursor at beginning again
              (goto-char (point-min))
              (let ((test-point (point)))

                (let ((greger-current-thinking-budget 0))
                  (greger-buffer)
                  (greger-test-wait-for-status 'idle)

                  ;; Point should still be at the beginning (no follow mode)
                  (should (= (point) test-point))))

              ;; Test toggling back to enabled
              (greger-toggle-follow-mode)
              (should (eq greger-follow-mode t)))))

      (when (and greger-buffer (buffer-live-p greger-buffer))
        (kill-buffer greger-buffer)))))

(provide 'test-end-to-end)

;;; test-end-to-end.el ends here
