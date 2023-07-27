;;; org-jira.el --- Syncing between Jira and Org-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2023 Karim Aziiev <karim.aziiev@gmail.com>
;; Copyright (C) 2016-2022 Matthew Carter <m@ahungry.com>
;; Copyright (C) 2011 Bao Haojun
;;
;; Authors:
;; Matthew Carter <m@ahungry.com>
;; Bao Haojun <baohaojun@gmail.com>
;; Karim Aziiev <karim.aziiev@gmail.com>
;;
;; Maintainer: Matthew Carter <m@ahungry.com>
;; URL: https://github.com/KarimAziev/org-jira
;; Version: 4.3.3
;; Keywords: tools
;; Package-Requires: ((emacs "28.1") (request "0.2.0") (dash "2.19.1") (org "9.6.7"))


;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; <http://www.gnu.org/licenses/> or write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301, USA.

;;; Commentary:

;; This provides an extension to org-mode for syncing issues with JIRA
;; issue servers.

;;; News:

;;;; Changes in 4.4.1
;; - Fix tag (4.3.3 was out of order - we had a 4.4.0 on repo)
;; - Fix for some crazy scoping issue in the org-jira-get-issue-val-from-org function

;;;; Changes in 4.3.3:
;; - Address issue with assignee property being removed when Unassigned

;;;; Changes in 4.3.2:
;; - Fixes issues with org-jira-add-comment and org-jira-update-comment

;;;; Changes in 4.3.1:
;; - Fix to make custom-jql results sync worklogs properly.

;;;; Changes in 4.3.0:
;; - Allow org-jira-set-issue-reporter call to dynamically set this value.

;;;; Changes in 4.1.0:
;; - Allow custom-jql to be specified and render in special files (see: README.md).

;;;; Changes in 4.0.0:
;; - Introduce SDK type for handling records vs random alist structures.

;;;; Changes since 3.1.0:
;; - Fix how we were ruining the kill-ring with kill calls.

;;;; Changes since 3.0.0:
;; - Add new org-jira-add-comment call (C-c c c)

;;;; Changes since 2.8.0:
;; - New version 3.0.0 deprecates old filing mechanism and files
;;   all of the changes under the top level ticket header.
;; - If you want other top level headers in the same file, this should
;;   work now, as long as they come after the main project one.

;;;; Changes since 2.7.0:
;; - Clean up multi-buffer handling, disable attachments call until
;; - refresh is compatible with it.

;;;; Changes since 2.6.3:
;; - Insert worklog import filter in the existing org-jira-update-worklogs-for-current-issue function
;; - Sync up org-clocks and worklogs!  Set org-jira-worklog-sync-p to nil to avoid.

;;;; Changes since 2.6.1:
;; - Fix bug with getting all issues when worklog is an error trigger.

;;;; Changes since 2.5.4:
;; - Added new org-jira-refresh-issues-in-buffer call and binding

;;;; Changes since 2.5.3:
;; - Re-introduce the commit that introduced a break into Emacs 25.1.1 list/array push
;;     The commit caused updates/comment updates to fail when a blank list of components
;;     was present - it will now handle both cases (full list, empty list).

;;;; Changes since 2.5.2:
;; - Revert a commit that introduced a break into Emacs 25.1.1 list/array push
;;     The commit caused updates/comment updates to fail

;;;; Changes since 2.5.1:
;; - Only set duedate if a DEADLINE is present in the tags and predicate is t

;;;; Changes since 2.5.0:
;; - Allow overriding the org property names with new defcustom

;;;; Changes since 2.4.0:
;; - Fix many deprecation/warning issues
;; - Fix error with allow-other-keys not being wrapped in cl-function

;;;; Changes since 2.3.0:
;; - Integration with org deadline and Jira due date fields

;;;; Changes since 2.2.0:
;; - Selecting issue type based on project key for creating issues

;;;; Changes since 2.1.0:
;; - Allow changing to unassigned user
;; - Add new shortcut for quick assignment

;;;; Changes since 2.0.0:
;; - Change statusCategory to status value
;; - Clean out some redundant code
;; - Add ELPA tags in keywords

;;;; Changes since 1.0.1:
;; - Converted many calls to async
;; - Removed minor annoyances (position resets etc.)

;;; Code:


(require 'cl-lib)
(require 'cl-extra)

(require 'org)
(require 'org-clock)
(require 'cl-lib)
(require 'url)
(require 'ls-lisp)
(require 'dash)
(require 'jiralib)
(require 'org-jira-sdk)



(defconst org-jira-version "4.3.1"
  "Current version of org-jira.el.")

(defgroup org-jira nil
  "Customization group for org-jira."
  :tag "Org JIRA"
  :group 'org)

(defcustom org-jira-working-dir "~/.org-jira"
  "Folder under which to store org-jira working files."
  :group 'org-jira
  :type 'directory)

(defcustom org-jira-project-filename-alist nil
  "Alist translating project keys to filenames.

Each element has a structure:

  (PROJECT-KEY . NEW-FILE-NAME)

where both are strings.  NEW-FILE-NAME is relative to
`org-jira-working-dir'."
  :group 'org-jira
  :type '(alist :key-type (string :tag "Project key")
                :value-type (string :tag "File name for this project")))

(defcustom org-jira-default-jql
  "assignee = currentUser() and resolution = unresolved ORDER BY
  priority DESC, created ASC"
  "Default jql for querying your Jira tickets."
  :group 'org-jira
  :type 'string)

(defcustom org-jira-ignore-comment-user-list
  '("admin")
  "Jira usernames that should have comments ignored."
  :group 'org-jira
  :type '(repeat (string :tag "Jira username:")))

(defcustom org-jira-reverse-comment-order nil
  "If non-nil, order comments from most recent to least recent."
  :group 'org-jira
  :type 'boolean)

(defcustom org-jira-done-states
  '("Closed" "Resolved" "Done")
  "Jira states that should be considered as DONE for `org-mode'."
  :group 'org-jira
  :type '(repeat (string :tag "Jira state name:")))

(defcustom org-jira-users
  '(("Full Name" . "account-id"))
  "A list of displayName and key pairs."
  :group 'org-jira
  :type 'list)

(defcustom org-jira-progress-issue-flow
  '(("To Do" . "In Progress")
    ("In Progress" . "Done"))
  "Quickly define a common issue flow."
  :group 'org-jira
  :type 'list)

(defcustom org-jira-property-overrides (list)
  "An assoc list of property tag overrides.

The KEY . VAL pairs should both be strings.

For instance, to change the :assignee: property in the org :PROPERTIES:
block to :WorkedBy:, you can set this as such:

  (setq org-jira-property-overrides (list (cons \"assignee\" \"WorkedBy\")))

or simply:

  (add-to-list (quote org-jira-property-overrides)
               (cons (\"assignee\" \"WorkedBy\")))

This will work for most any of the properties, with the
exception of ones with unique functionality, such as:

  - deadline
  - summary
  - description"
  :group 'org-jira
  :type 'list)

(defcustom org-jira-serv-alist nil
  "Association list to set information for each jira server.
Each element of the alist is a jira server name.  The CAR of each
element is a string, uniquely identifying the server.  The CDR of
each element is a well-formed property list with an even number
of elements, alternating keys and values, specifying parameters
for the server.

     (:property value :property value ... )

When a property is given a value in `org-jira-serv-alist', its
setting overrides the value of the corresponding user
variable (if any) during syncing.

Most properties are optional, but some should always be set:

  :url        soap url of the jira server.
  :username   username to be used.
  :host       hostname of the jira server (TODO: compute it from ~url~).

All the other properties are optional.  They override the global
variables.

  :password   password to be used, will be prompted if missing."
  :group 'org-jira
  :type '(alist :value-type plist))

(defcustom org-jira-use-status-as-todo t
  "Use the JIRA status as the TODO tag value."
  :type 'boolean
  :group 'org-jira)

(defcustom org-jira-deadline-duedate-sync-p t
  "Keep org deadline and jira duedate fields synced.
You may wish to set this to nil if you track org deadlines in
your buffer that you do not want to send back to your Jira
instance."
  :group 'org-jira
  :type 'boolean)

(defcustom org-jira-worklog-sync-p t
  "Keep org clocks and jira worklog fields synced.
You may wish to set this to nil if you track org clocks in
your buffer that you do not want to send back to your Jira
instance."
  :group 'org-jira
  :type 'boolean)

(defcustom org-jira-download-dir "~/Downloads"
  "Name of the default jira download library."
  :group 'org-jira
  :type 'string)

(defcustom org-jira-download-ask-override t
  "Ask before overriding tile."
  :group 'org-jira
  :type 'boolean)

(defcustom org-jira-jira-status-to-org-keyword-alist nil
  "Custom alist of jira status stored in car and `org-mode' keyword stored in cdr."
  :group 'org-jira
  :type '(alist :key-type string :value-type string))

(defcustom org-jira-priority-to-org-priority-omit-default-priority nil
  "Whether to omit insertion of priority when it matches the default.

When set to t, will omit the insertion of the matched value from
`org-jira-priority-to-org-priority-alist' when it matches the
`org-default-priority'."
  :group 'org-jira
  :type 'boolean)

(defcustom org-jira-priority-to-org-priority-alist nil
  "Alist mapping jira priority keywords to `org-mode' priority cookies.

A sample value might be
  (list (cons \"High\" ?A)
        (cons \"Medium\" ?B)
        (cons \"Low\" ?C)).

See `org-default-priority' for more info."
  :group 'org-jira
  :type '(alist :key-type string :value-type character))

(defcustom org-jira-boards-default-limit 50
  "Default limit for number of issues retrieved from agile boards."
  :group 'org-jira
  :type 'integer)

;; FIXME: Issue with using this - issues are grouped under a headline incorrectly.
(defcustom org-jira-custom-jqls '((:jql
                                   " assignee = currentUser() and createdDate < '2019-01-01' order by created DESC "
                                   :limit 100
                                   :filename "last-years-work")
                                  (:jql
                                   " assignee = currentUser() and createdDate >= '2019-01-01' order by created DESC "
                                   :limit 100
                                   :filename "this-years-work"))
  "A list of plists with :jql and :filename keys to run arbitrary user JQL."
  :group 'org-jira
  :type '(alist :value-type plist))

(defcustom org-jira-download-comments t
  "Set to nil if you don't want to update comments during issue rendering."
  :group 'org-jira
  :type 'boolean)

(defvar org-jira-serv nil
  "Parameters of the currently selected blog.")

(defvar org-jira-serv-name nil
  "Name of the blog, to pick from `org-jira-serv-alist'.")

(defvar org-jira-projects-list nil
  "List of jira projects.")

(defvar org-jira-current-project nil
  "Currently selected (i.e., active project).")

(defvar org-jira-issues-list nil
  "List of jira issues under the current project.")

(defvar org-jira-server-rpc-url nil
  "Jira server soap URL.")

(defvar org-jira-server-userid nil
  "Jira server user id.")

(defvar org-jira-proj-id nil
  "Jira project ID.")

(defvar org-jira-logged-in nil
  "Flag whether user is logged-in or not.")

(defvar org-jira-buffer-name "*org-jira-%s*"
  "Name of the jira buffer.")

(defvar org-jira-buffer-kill-prompt t
  "Ask before killing buffer.")

(make-variable-buffer-local 'org-jira-buffer-kill-prompt)

(defvar org-jira-mode-hook nil
  "Hook to run upon entry into mode.")

(defvar org-jira-issue-id-history '()
  "Prompt history for issue id.")

(defvar org-jira-fixversion-id-history '()
  "Prompt history for fixversion id.")

(defvar org-jira-verbosity 'debug)

(defun org-jira-log (s)
  "Prints debug message if `org-jira-verbosity' is set to debug.

Argument S is the message to be logged."
  (when (eq 'debug org-jira-verbosity)
    (message "%s" s)))

(defmacro org-jira-ensure-on-issue (&rest body)
  "Make sure we are on an issue heading, before executing BODY."
  (declare (debug t)
           (indent 0))
  `(save-excursion
     (save-restriction
       (widen)
       (unless (looking-at "^\\*\\* ")
         (search-backward-regexp "^\\*\\* " nil t)) ; go to top heading
       (let ((org-jira-id (org-jira-id)))
         (unless (and org-jira-id (string-match (jiralib-get-issue-regexp)
                                                (downcase org-jira-id)))
           (error "Not on an issue region!")))
       ,@body)))

(defmacro org-jira-with-callback (&rest body)
  "Simpler way to write the data BODY callbacks."
  (declare (debug t)
           (indent 0))
  `(lambda (&rest request-response)
     (let ((cb-data (cl-getf request-response :data)))
       cb-data
       ,@body)))

(defmacro org-jira-freeze-ui (&rest body)
  "Freeze the UI layout for the user as much as possible and execute BODY."
  (declare (debug t)
           (indent 0))
  `(save-excursion
     (save-restriction
       (widen)
       (org-save-outline-visibility t
         (outline-show-all)
         ,@body))))

(eval-and-compile (defun org-jira-mini-fp--expand (init-fn)
  "If INIT-FN is a non-quoted symbol, add a sharp quote.
Otherwise, return it as is."
  (setq init-fn (macroexpand init-fn))
  (if (symbolp init-fn)
      `(#',init-fn)
    `(,init-fn))))

(defmacro org-jira-mini-fp-pipe (&rest functions)
  "Return a left-to-right composition from FUNCTIONS.
The first argument may have any arity; the remaining arguments must be unary."
  (declare (debug t)
           (pure t)
           (side-effect-free t))
  (let ((args (make-symbol "args")))
    `(lambda (&rest ,args)
       ,@(let ((init-fn (pop functions)))
           (list
            (seq-reduce
             (lambda (acc fn)
               `(funcall ,@(org-jira-mini-fp--expand fn) ,acc))
             functions
             `(apply ,@(org-jira-mini-fp--expand init-fn) ,args)))))))

(defmacro org-jira-mini-fp-compose (&rest functions)
  "Return a right-to-left composition from FUNCTIONS.
The last function may have any arity; the remaining arguments must be unary."
  (declare (debug t)
           (pure t)
           (side-effect-free t))
  `(org-jira-mini-fp-pipe ,@(reverse functions)))

(defmacro org-jira-mini-fp-or (&rest functions)
  "Expand to a unary function that call FUNCTIONS until first non-nil result.
Return that first non-nil result without calling the remaining functions.
If all functions returned nil, the result will be also nil."
  (declare (debug t)
           (pure t)
           (side-effect-free t))
  (let ((it (make-symbol "it")))
    `(lambda (,it)
       (or
        ,@(mapcar (lambda (v)
                    `(funcall ,@(org-jira-mini-fp--expand v) ,it))
                  functions)))))

(defmacro org-jira-mini-fp-and (&rest functions)
  "Return a unary function that call FUNCTIONS until one of them yields nil.
If all functions return non-nil, return the last such value."
  (declare (debug t)
           (pure t)
           (side-effect-free t))
  (let ((it (make-symbol "it")))
    `(lambda (,it)
       (and
        ,@(mapcar (lambda (v)
                    `(funcall ,@(org-jira-mini-fp--expand v) ,it))
                  functions)))))

(defmacro org-jira-mini-fp-partial (fn &rest args)
  "Return a partial application of a function FN to left-hand ARGS.

ARGS is a list of the last N arguments to pass to FN. The result is a new
function that does the same as FN, except that the last N arguments are fixed
at the values with which this function was called."
  (declare (side-effect-free t))
  (let ((pre-args (make-symbol "pre-args")))
    `(lambda (&rest ,pre-args)
       ,(car (list
              `(apply ,@(org-jira-mini-fp--expand fn)
                      (append (list ,@args) ,pre-args)))))))

(defmacro org-jira-mini-fp-rpartial (fn &rest args)
  "Return a partial application of a function FN to right-hand ARGS.

ARGS is a list of the last N arguments to pass to FN. The result is a new
function which does the same as FN, except that the last N arguments are fixed
at the values with which this function was called."
  (declare (side-effect-free t))
  (let ((pre-args (make-symbol "pre-args")))
    `(lambda (&rest ,pre-args)
       ,(car (list
              `(apply ,@(org-jira-mini-fp--expand fn)
                      (append ,pre-args (list ,@args))))))))

(defmacro org-jira-mini-fp-converge (combine-fn &rest functions)
  "Return a function to apply COMBINE-FN with the results of branching FUNCTIONS.
If the first element of FUNCTIONS is a vector, it will be used instead.

Example:

\(funcall (org-jira-mini-fp-converge concat [upcase downcase]) \"John\").
\(funcall (org-jira-mini-fp-converge concat upcase downcase) \"John\")

Result: \"JOHNjohn\"."
  (let ((args (make-symbol "args")))
    `(lambda (&rest ,args)
       (apply
        ,@(org-jira-mini-fp--expand combine-fn)
        (list
         ,@(mapcar (lambda (v)
                     `(apply ,@(org-jira-mini-fp--expand v) ,args))
                   (if (vectorp (car functions))
                       (append (car functions) nil)
                     functions)))))))

(defmacro org-jira-mini-fp-use-with (combine-fn &rest functions)
  "Return a function with the arity of length FUNCTIONS.
Call every branching function with an argument at the same index,
and finally, COMBINE-FN will be applied to the supplied values.

Example:

\(funcall (org-jira-mini-fp-use-with concat [upcase downcase])
 \"hello \" \"world\")


If first element of FUNCTIONS is vector, it will be used instead:

\(funcall (org-jira-mini-fp-use-with + [(org-jira-mini-fp-partial 1+)
identity]) 2 2)
=> Result: 5

\(funcall (org-jira-mini-fp-use-with + (org-jira-mini-fp-partial 1+)
identity) 2 2)
=> Result: 5

=> Result: \"HELLO world\"."
  (let ((args (make-symbol "args")))
    `(lambda (&rest ,args)
       (apply
        ,@(org-jira-mini-fp--expand combine-fn)
        (list
         ,@(seq-map-indexed (lambda (v idx)
                              `(funcall ,@(org-jira-mini-fp--expand v)
                                        (nth ,idx ,args)))
                            (if (vectorp (car functions))
                                (append (car functions) nil)
                              functions)))))))

(defmacro org-jira-mini-fp-when (pred fn)
  "Return a function that call FN if the result of calling PRED is non-nil.
Both PRED and FN are called with one argument.
If the result of PRED is nil, return the argument as is."
  (declare
   (indent defun))
  (let ((arg (make-symbol "arg")))
    `(lambda (,arg)
       (if
           (funcall ,@(org-jira-mini-fp--expand pred) ,arg)
           (funcall ,@(org-jira-mini-fp--expand fn) ,arg)
         ,arg))))

(defmacro org-jira-mini-fp-unless (pred fn)
  "Return a unary function that invokes FN if the result of calling PRED is nil.
Accept one argument and pass it both to PRED and FN.
If the result of PRED is non-nil, return the argument as is."
  (let ((arg (make-symbol "arg")))
    `(lambda (,arg)
       (if (funcall ,@(org-jira-mini-fp--expand pred) ,arg)
           ,arg
         (funcall ,@(org-jira-mini-fp--expand fn) ,arg)))))

(defmacro org-jira-mini-fp-const (value)
  "Return a function that always return VALUE.
This function accepts any number of arguments but ignores them."
  (declare (pure t)
           (side-effect-free error-free))
  (let ((arg (make-symbol "_")))
    `(lambda (&rest ,arg) ,value)))

(defmacro org-jira-mini-fp-ignore-args (fn)
  "Return a function that invokes FN without args.
This function accepts any number of arguments but ignores them."
  (declare
   (indent defun))
  (let ((arg (make-symbol "_")))
    `(lambda (&rest ,arg)
       (funcall ,@(org-jira-mini-fp--expand fn)))))

(defmacro org-jira-mini-fp-cond (&rest pairs)
  "Return a function that expands a list of PAIRS to cond clauses.
Every pair should be either:
- a vector of [predicate transformer],
- a list of (predicate transformer).

The predicate can also be t.

All of the arguments to function are applied to each of the predicates in turn
until one returns a \"truthy\" value, at which point fn returns the result of
applying its arguments to the corresponding transformer."
  (declare (pure t)
           (indent defun)
           (side-effect-free error-free))
  (setq pairs (mapcar (lambda (it)
                        (if (listp it)
                            (apply #'vector it)
                          it))
                      pairs))
  (let ((args (make-symbol "args")))
    `(lambda (&rest ,args)
       (cond ,@(mapcar (lambda (v)
                         (list (if (eq (aref v 0) t) t
                                 `(apply ,@(org-jira-mini-fp--expand (aref v 0)) ,args))
                               `(apply ,@(org-jira-mini-fp--expand (aref v 1)) ,args)))
                       pairs)))))

(defmacro org-jira-mini-fp-not (fn)
  "Return a function that negates the result of function FN."
  `(org-jira-mini-fp-compose not ,fn))


(defvar org-jira-proj-key-override nil
  "String.  An override for the proj-key.  Set to nil to restore old behavior.")

;; We want some hooking system to override default-jql + this.
(defun org-jira--get-proj-key (issue-id)
  "Get the proper proj-key.  Typically derived from ISSUE-ID."
  (if org-jira-proj-key-override org-jira-proj-key-override
    (replace-regexp-in-string "-.*" "" issue-id)))

(defun org-jira--get-proj-key-from-issue (Issue)
  "Get the proper proj-key from an ISSUE instance."
  (oref Issue filename))

;; TODO: Merge these 3 ensure macros (or, scrap all but ones that work on Issue)
(defmacro org-jira-ensure-on-issue-id (issue-id &rest body)
  "Just do some work on ISSUE-ID, execute BODY."
  (declare (debug t)
           (indent 1))
  (let ((issue-id-var (make-symbol "issue-id")))
    `(let* ((,issue-id-var ,issue-id)
            (proj-key (org-jira--get-proj-key ,issue-id-var))
            (project-file (org-jira--get-project-file-name proj-key))
            (project-buffer (or (find-buffer-visiting project-file)
                                (find-file project-file))))
       (with-current-buffer project-buffer
         (org-jira-freeze-ui
           (let ((p (org-find-entry-with-id ,issue-id-var)))
             (unless p (error "Issue %s not found!" ,issue-id-var))
             (goto-char p)
             (org-narrow-to-subtree)
             ,@body))))))

(defmacro org-jira-ensure-on-issue-id-with-filename (issue-id filename &rest
                                                              body)
  "Ensure that the issue with the given ID and FILENAME exists and perform.

Argument BODY is a body of code that will be executed within the macro.
Argument FILENAME is the name of the file associated with the issue.
Argument ISSUE-ID is the ID of the issue that needs to be ensured."
  (declare (debug t)
           (indent 1))
  (let ((issue-id-var (make-symbol "issue-id"))
        (filename-var (make-symbol "filename")))
    `(let* ((,issue-id-var ,issue-id)
            (,filename-var ,filename)
            (proj-key ,filename-var)
            (project-file (org-jira--get-project-file-name proj-key))
            (project-buffer (or (find-buffer-visiting project-file)
                                (find-file project-file))))
       (with-current-buffer project-buffer
         (org-jira-freeze-ui
           (let ((p (org-find-entry-with-id ,issue-id-var)))
             (unless p (error "Issue %s not found!" ,issue-id-var))
             (goto-char p)
             (org-narrow-to-subtree)
             ,@body))))))

(defmacro org-jira-ensure-on-issue-Issue (Issue &rest body)
  "Just do some work on ISSUE, execute BODY."
  (declare (debug t)
           (indent 1))
  (let ((Issue-var (make-symbol "Issue")))
    `(let ((,Issue-var ,Issue))
       (with-slots (issue-id) ,Issue-var
         (let* ((proj-key (org-jira--get-proj-key-from-issue ,Issue-var))
                (project-file (org-jira--get-project-file-name proj-key))
                (project-buffer (or (find-buffer-visiting project-file)
                                    (find-file project-file))))
           (with-current-buffer project-buffer
             (org-jira-freeze-ui
               (let ((p (org-find-entry-with-id issue-id)))
                 (unless p (error "Issue %s not found!" issue-id))
                 (goto-char p)
                 (org-narrow-to-subtree)
                 ,@body))))))))

(defmacro org-jira-ensure-on-todo (&rest body)
  "Make sure we are on an todo heading, before executing BODY."
  (declare (debug t)
           (indent 0))
  `(save-excursion
     (save-restriction
       (let ((continue t)
             (on-todo nil))
         (while continue
           (when (org-get-todo-state)
             (setq continue nil on-todo t))
           (unless (and continue (org-up-heading-safe))
             (setq continue nil)))
         (if (not on-todo)
             (error "TODO not found")
           (org-narrow-to-subtree)
           ,@body)))))

(defmacro org-jira-ensure-on-comment (&rest body)
  "Make sure we are on a comment heading, before executing BODY."
  (declare (debug t)
           (indent 0))
  `(save-excursion
     (org-back-to-heading)
     (forward-thing 'whitespace)
     (unless (looking-at "Comment:")
       (error "Not on a comment region!"))
     (save-restriction
       (org-narrow-to-subtree)
       ,@body)))

(defmacro org-jira-ensure-on-worklog (&rest body)
  "Make sure we are on a worklog heading, before executing BODY."
  (declare (debug t)
           (indent 0))
  `(save-excursion
     (org-back-to-heading)
     (forward-thing 'whitespace)
     (unless (looking-at "Worklog:")
       (error "Not on a worklog region!"))
     (save-restriction
       (org-narrow-to-subtree)
       ,@body)))

(defun org-jira--ensure-working-dir ()
  "Ensure that the `org-jira-working-dir' exists."
  (unless (file-exists-p org-jira-working-dir)
    (error (format
            "org-jira directory does not exist! Run (make-directory \"%s\")"
            org-jira-working-dir)))
  org-jira-working-dir)

(defvar org-jira-entry-mode-map
  (let ((org-jira-map (make-sparse-keymap)))
    (define-key org-jira-map (kbd "C-c C-j") #'org-jira-menu)
    org-jira-map))

;;;###autoload
(define-minor-mode org-jira-mode
  "Toggle org-jira mode.
With no argument, the mode is toggled on/off.
Non-nil argument turns mode on.
Nil argument turns mode off.

Commands:
\\{org-jira-entry-mode-map}

Entry to this mode calls the value of `org-jira-mode-hook'."

  :init-value nil
  :lighter " jira"
  :group 'org-jira
  :keymap org-jira-entry-mode-map

  (if org-jira-mode
      (progn
        (set (make-local-variable 'org-element-use-cache) nil)
        (run-mode-hooks 'org-jira-mode-hook))
    (progn
      (kill-local-variable 'org-element-use-cache))))

(defun org-jira-maybe-activate-mode ()
  "Re-activate the `org-jira-mode' if it isn't already on."
  (unless (bound-and-true-p org-jira-mode) (org-jira-mode t)))

(defun org-jira-get-project-name (proj)
  "Get project name from JIRA using project key.

Argument PROJ is the project identifier used to retrieve the project name."
  (org-jira-find-value proj 'key))

(defun org-jira-find-value (l &rest keys)
  "Find a value in a list of `key-value' pairs.

Argument KEYS is a variable number of keys that will be used to search for a
value in the list L."
  (let* (key exists)
    (while (and keys (listp l))
      (setq key (car keys))
      (setq exists nil)
      (mapc (lambda (item)
              (when (equal key (car item))
                (setq exists t)))
            (if (and (listp l)
                     (listp (car l)))
                l
              nil))
      (setq keys (cdr keys))
      (if exists
          (setq l (cdr (assoc key l)))
        (setq l (or (cdr (assoc key l)) l))))
    l))

(defun org-jira--get-project-file-name (project-key)
  "Translate PROJECT-KEY into filename."
  (-if-let (translation (cdr (assoc project-key org-jira-project-filename-alist)))
      (expand-file-name translation (org-jira--ensure-working-dir))
    (expand-file-name (concat project-key ".org") (org-jira--ensure-working-dir))))

(defun org-jira-get-project-lead (proj)
  "Get the project lead's name for a given project.

Argument PROJ is the project for which we want to retrieve the name of the
project lead."
  (org-jira-find-value proj 'lead 'name))

;; This is mapped to accountId and not username, so we need nil not blank string.
(defun org-jira-get-assignable-users (project-key)
  "Get the list of assignable users for PROJECT-KEY."
  (append
   '(("Unassigned" . nil))
   org-jira-users
   (mapcar (lambda (user)
             (cons (org-jira-decode (cdr (assoc 'displayName user)))
                   (org-jira-decode (cdr (assoc 'accountId user)))))
           (jiralib-get-users project-key))))

(defun org-jira-get-reporter-candidates (project-key)
  "Get the list of assignable users for PROJECT-KEY."
  (append
   org-jira-users
   (mapcar (lambda (user)
             (cons (org-jira-decode (cdr (assoc 'displayName user)))
                   (org-jira-decode (cdr (assoc 'accountId user)))))
           (jiralib-get-users project-key))))

(defun org-jira-entry-put (pom property value)
  "Similar to `org-jira-entry-put', but with an optional alist of overrides.

At point-or-marker POM, set PROPERTY to VALUE.

Look at customizing `org-jira-property-overrides' if you want
to change the property names this sets."
  (unless (stringp property)
    (setq property (symbol-name property)))
  (let ((property (or (assoc-default property org-jira-property-overrides)
                      property)))
    (org-entry-put pom property (org-jira-decode value))))

;;;###autoload
(defun org-jira-kill-line ()
  "Kill the line, without `kill-line' side-effects of altering kill ring."
  (interactive)
  (delete-region (point)
                 (line-end-position)))

;; Appropriated from org.el
(defun org-jira-org-kill-line (&optional _arg)
  "Kill line, to tags or end of line."
  (cond ((or (not org-special-ctrl-k)
             (bolp)
             (not (org-at-heading-p)))
         (when
             (and (get-char-property (min (point-max)
                                          (line-end-position)) 'invisible)
                  org-ctrl-k-protect-subtree
                  (or (eq org-ctrl-k-protect-subtree 'error)
                      (not
                       (y-or-n-p "Kill hidden subtree along with headline? "))))
           (user-error "C-k aborted as it would kill a hidden subtree"))
         (call-interactively
          (if (bound-and-true-p visual-line-mode) 'kill-visual-line
            'org-jira-kill-line)))
        ((looking-at ".*?\\S-\\([ \t]+\\(:[[:alnum:]_@#%:]+:\\)\\)[ \t]*$")
         (delete-region (point)
                        (match-beginning 1))
         (org-set-tags nil))
        (t (delete-region (point)
                          (line-end-position)))))

;;;###autoload
(defun org-jira-get-projects ()
  "Get list of projects."
  (interactive)
  (let ((projects-file (expand-file-name "projects-list.org"
                                         (org-jira--ensure-working-dir))))
    (or (find-buffer-visiting projects-file)
        (find-file projects-file))
    (org-jira-maybe-activate-mode)
    (save-excursion
      (let* ((oj-projs (jiralib-get-projects)))
        (mapc (lambda (proj)
                (let* ((proj-key (org-jira-find-value proj 'key))
                       (proj-headline (format "Project: [[file:%s.org][%s]]"
                                              proj-key proj-key)))
                  (save-restriction
                    (widen)
                    (goto-char (point-min))
                    (outline-show-all)
                    (let ((p (org-find-exact-headline-in-buffer proj-headline)))
                      (if (and p (>= p (point-min))
                               (<= p (point-max)))
                          (progn
                            (goto-char p)
                            (org-narrow-to-subtree)
                            (end-of-line))
                        (goto-char (point-max))
                        (unless (looking-at "^")
                          (insert "\n"))
                        (insert "* ")
                        (org-jira-insert proj-headline)
                        (org-narrow-to-subtree)))
                    (org-jira-entry-put (point) "name" (org-jira-get-project-name
                                                        proj))
                    (org-jira-entry-put (point) "key" (org-jira-find-value proj
                                                                           'key))
                    (org-jira-entry-put (point) "lead" (org-jira-get-project-lead
                                                        proj))
                    (org-jira-entry-put (point) "ID" (org-jira-find-value proj
                                                                          'id))
                    (org-jira-entry-put (point) "url" (format "%s/browse/%s" (replace-regexp-in-string
                                                                              "/*$" "" jiralib-url)
                                                              (org-jira-find-value proj 'key))))))
              oj-projs)))))

(defun org-jira-get-issue-components (issue)
  "Return the components the ISSUE belongs to."
  (mapconcat
   (lambda (comp)
     (org-jira-find-value comp 'name))
   (org-jira-find-value issue 'fields 'components) ", "))

(defun org-jira-get-issue-labels (issue)
  "Return the labels the ISSUE belongs to."
  (org-jira-find-value issue 'fields 'labels))

(defun org-jira-decode (data)
  "Decode text DATA.

It must receive a coercion to string, as not every time will it
be populated."
  (decode-coding-string
   (when (fboundp 'cl-coerce)
     (cl-coerce data 'string))
   jiralib-coding-system))

(defun org-jira-insert (&rest args)
  "Set coding to text provide by `ARGS' when insert in buffer."
  (insert (org-jira-decode (apply #'concat args))))

(defun org-jira-transform-time-format (jira-time-str)
  "Convert JIRA-TIME-STR to format \"%Y-%m-%d %T\".

Example: \"2012-01-09T08:59:15.000Z\" becomes \"2012-01-09
16:59:15\", with the current timezone being +0800."
  (condition-case ()
      (format-time-string
       "%Y-%m-%d %T"
       (apply
        #'encode-time
        (parse-time-string (replace-regexp-in-string "T\\|\\.000" " " jira-time-str))))
    (error jira-time-str)))

(defun org-jira--fix-encode-time-args (arg)
  "Fix ARG for 3 nil values at the head."
  (cl-loop
   for n from 0 to 2 by 1 do
   (when (not (nth n arg))
     (setcar (nthcdr n arg) 0)))
  arg)

(defun org-jira-time-format-to-jira (org-time-str)
  "Convert ORG-TIME-STR back to jira time format."
  (condition-case ()
      (format-time-string
       "%Y-%m-%dT%T.000Z"
       (apply #'encode-time
              (org-jira--fix-encode-time-args (parse-time-string org-time-str)))
       t)
    (error org-time-str)))

(defun org-jira-get-comment-val (key comment)
  "Return the value associated with KEY of COMMENT."
  (org-jira-get-issue-val key comment))

(defun org-jira-time-stamp-to-org-clock (time-stamp)
  "Convert TIME-STAMP into org-clock format."
  (format-time-string "%Y-%m-%d %a %H:%M" time-stamp))

(defun org-jira-date-to-org-clock (date)
  "Convert DATE into a time stamp and then into org-clock format.
Expects a date in format such as: 2017-02-26T00:08:00.000-0500."
  (org-jira-time-stamp-to-org-clock (date-to-time date)))

(defun org-jira-worklogs-to-org-clocks (worklogs)
  "Get a list of WORKLOGS and convert to org-clocks."
  (mapcar
   (lambda (worklog)
     (let ((wl-start (cdr (assoc 'started worklog)))
           (wl-time (cdr (assoc 'timeSpentSeconds worklog)))
           (wl-end))
       (setq wl-start (org-jira-date-to-org-clock wl-start))
       (setq wl-end (org-jira-time-stamp-to-org-clock (time-add (date-to-time wl-start) wl-time)))
       (list
        wl-start
        wl-end
        (cdr (assoc 'comment worklog))
        (cdr (assoc 'id worklog)))))
   worklogs))

(defun org-jira-format-clock (clock-entry)
  "Format a CLOCK-ENTRY given the (list start end).
This format is typically generated from `org-jira-worklogs-to-org-clocks' call."
  (format "CLOCK: [%s]--[%s]" (car clock-entry)
          (cadr clock-entry)))

(defun org-jira-insert-clock (clock-entry)
  "Insert a CLOCK-ENTRY given the (list start end).
This format is typically generated from `org-jira-worklogs-to-org-clocks' call."
  (insert (org-jira-format-clock clock-entry))
  (org-beginning-of-line)
  (org-ctrl-c-ctrl-c)
  (org-end-of-line)
  (insert "\n")
  (insert (format "  :id: %s\n" (cadddr clock-entry)))
  (when (caddr clock-entry)
    (insert (replace-regexp-in-string
             "^\\*" "-" (format "  %s\n" (org-jira-decode (caddr clock-entry)))))))

;;;###autoload
(defun org-jira-logbook-reset (issue-id filename &optional clocks)
  "Find logbook for ISSUE-ID in FILENAME, delete it.
Re-create it with CLOCKS.  This is used for worklogs."
  (interactive)
  (let ((existing-logbook-p nil))
    ;; See if the LOGBOOK already exists or not.
    (org-jira-ensure-on-issue-id-with-filename issue-id filename
      (let ((drawer-name (or (org-clock-drawer-name) "LOGBOOK")))
        (when (search-forward (format ":%s:" drawer-name) nil 1 1)
          (setq existing-logbook-p t))))
    (org-jira-ensure-on-issue-id-with-filename issue-id filename
      (let ((drawer-name (or (org-clock-drawer-name) "LOGBOOK")))
        (if existing-logbook-p
            (progn ;; If we had a logbook, drop it and re-create in a bit.
              (search-forward (format ":%s:" drawer-name) nil 1 1)
              (org-beginning-of-line)
              (delete-region (point) (search-forward ":END:" nil 1 1)))
          (progn ;; Otherwise, create a new one at the end of properties list
            (search-forward ":END:" nil 1 1)
            (forward-line)))
        (org-insert-drawer nil (format "%s" drawer-name)) ;; Doc says non-nil, but this requires nil
        (mapc #'org-jira-insert-clock clocks)
        ;; Clean up leftover newlines (we left 2 behind)
        (dotimes (_n 2)
          (search-forward-regexp "^$" nil 1 1)
          (delete-region (point) (min (point-max) (1+ (point)))))))))

(defun org-jira-get-worklog-val (key WORKLOG)
  "Return the value associated with KEY of WORKLOG."
  (org-jira-get-comment-val key WORKLOG))

(defun org-jira-get-issue-val (key issue)
  "Return the value associated with key KEY of issue ISSUE."
  (let ((tmp  (or (org-jira-find-value issue 'fields key 'key) ""))) ;; For project, we need a key, not the name...
    (unless (stringp tmp)
      (setq tmp (org-jira-find-value issue key)))
    (unless (stringp tmp)
      (setq tmp (org-jira-find-value issue 'fields key 'displayName)))
    (unless (stringp tmp)
      (setq tmp ""))
    (cond ((eq key 'components)
           (org-jira-get-issue-components issue))
          ((eq key 'labels)
           (org-jira-get-issue-labels issue))
          ((member key '(created updated startDate))
           (org-jira-transform-time-format tmp))
          ((eq key 'status)
           (if jiralib-use-restapi
               (org-jira-find-value issue 'fields 'status 'name)
             (org-jira-find-value (jiralib-get-statuses) tmp)))
          ((eq key 'resolution)
           (if jiralib-use-restapi
               tmp
             (if (string= tmp "")
                 ""
               (org-jira-find-value (jiralib-get-resolutions) tmp))))
          ((eq key 'type)
           (if jiralib-use-restapi
               (org-jira-find-value issue 'fields 'issuetype 'name)
             (org-jira-find-value (jiralib-get-issue-types) tmp)))
          ((eq key 'priority)
           (if jiralib-use-restapi
               (org-jira-find-value issue 'fields 'priority 'name)
             (org-jira-find-value (jiralib-get-priorities) tmp)))
          ((eq key 'description)
           (org-trim tmp))
          (t
           tmp))))

(defvar org-jira-jql-history nil)

;;;###autoload
(defun org-jira-get-issue-list (&optional callback)
  "Get list of issues, using jql (jira query language), invoke CALLBACK after.

Default is unresolved issues assigned to current login user; with
a prefix argument you are given the chance to enter your own
jql."
  (org-jira-log (format "I was called, was it with a callback? %s" (if callback "yes" "no")))
  (let ((jql org-jira-default-jql))
    (when current-prefix-arg
      (setq jql (read-string "Jql: "
                             (if org-jira-jql-history
                                 (car org-jira-jql-history)
                               "assignee = currentUser() and resolution = unresolved")
                             'org-jira-jql-history
                             "assignee = currentUser() and resolution = unresolved")))
    (list (jiralib-do-jql-search jql nil callback))))

(defun org-jira-get-issue-by-id (id)
  "Get an issue by its ID."
  (push id org-jira-issue-id-history)
  (let ((jql (format "id = %s" id)))
    (jiralib-do-jql-search jql)))

(defun org-jira-get-issue-by-fixversion (fixversion-id)
  "Get an issue by its FIXVERSION-ID."
  (push fixversion-id org-jira-fixversion-id-history)
  (let ((jql (format "fixVersion = \"%s\""  fixversion-id)))
    (jiralib-do-jql-search jql)))

;;;###autoload
(defun org-jira-get-summary ()
  "Get issue summary from point and place next to issue id from jira."
  (interactive)
  (let ((jira-id (thing-at-point 'symbol)))
    (unless jira-id (error
                     "ORG_JIRA_ERROR: JIRA-ID missing in org-jira-get-summary!"))
    (forward-symbol 1)
    (insert (format " - %s"
                    (cdr (assoc 'summary (assoc 'fields (car (org-jira-get-issue-by-id
                                                              jira-id)))))))))

;;;###autoload
(defun org-jira-get-summary-url ()
  "Get issue summary from point and place next to issue id from jira.
Then make issue id a link"
  (interactive)
  (let ((jira-id (thing-at-point 'symbol)))
    (insert (format "[[%s][%s]] - %s"
                    (cl-concatenate 'string jiralib-url "browse/" jira-id)
                    jira-id
                    (cdr (assoc 'summary
                                (car (org-jira-get-issue-by-id jira-id))))))))

;;;###autoload
(defun org-jira-get-issues-headonly (issues)
  "Get list of ISSUES, head only.

The default behavior is to return issues assigned to you and unresolved.

With a prefix argument, allow you to customize the jql.  See
`org-jira-get-issue-list'."

  (interactive
   (org-jira-get-issue-list))

  (let* ((issues-file (expand-file-name "issues-headonly.org" (org-jira--ensure-working-dir)))
         (issues-headonly-buffer (or (find-buffer-visiting issues-file)
                                     (find-file issues-file))))
    (with-current-buffer issues-headonly-buffer
      (widen)
      (delete-region (point-min) (point-max))

      (mapc (lambda (issue)
              (let ((issue-id (org-jira-get-issue-key issue))
                    (issue-summary (org-jira-get-issue-summary issue)))
                (org-jira-insert (format "- [jira:%s] %s\n" issue-id issue-summary))))
            issues))
    (switch-to-buffer issues-headonly-buffer)))

;;;###autoload
(defun org-jira-get-issue (id)
  "Get and display a JIRA issue in `org-mode'.

Argument ID is the identifier of the JIRA issue that the function will retrieve
and display."
  
  (interactive (list (read-string "Issue ID: " "" 'org-jira-issue-id-history)))
  (org-jira-get-issues (org-jira-get-issue-by-id id))
  (let ((issue-pos (org-find-entry-with-id id)))
    (when issue-pos
      (goto-char issue-pos)
      (recenter 0))))
;;;###autoload
(defun org-jira-get-issues-by-fixversion (fixversion)
  "Get list of issues by FIXVERSION."
  (interactive (list (read-string "Fixversion ID: " ""
                                  'org-jira-fixversion-id-history)))
  (org-jira-get-issues (org-jira-get-issue-by-fixversion fixversion)))

;;;###autoload
(defun org-jira-get-issue-project (issue)
  "Get project key of a JIRA ISSUE.

Argument ISSUE is missing a required argument."
  (org-jira-find-value issue 'fields 'project 'key))

(defun org-jira-get-issue-key (issue)
  "Get JIRA ISSUE key from given ISSUE.

Argument ISSUE is missing a required argument."
  (org-jira-find-value issue 'key))

(defun org-jira-get-issue-summary (issue)
  "Get ISSUE summary from JIRA.

Argument ISSUE is missing a required argument."
  (org-jira-find-value issue 'fields 'summary))

(defvar org-jira-get-issue-list-callback
  (cl-function
   (lambda (&key data &allow-other-keys)
     "Callback for async, DATA is the response from the request call.

Will send a list of org-jira-sdk-issue objects to the list printer."
     (org-jira-log "Received data for org-jira-get-issue-list-callback.")
     (--> data
          (org-jira-sdk-path it '(issues))
          (append it nil)               ; convert the conses into a proper list.
          org-jira-sdk-create-issues-from-data-list
          org-jira-get-issues))))

(defvar org-jira-get-sprint-list-callback
  (cl-function
   (lambda (&key data &allow-other-keys)
     "Callback for async, DATA is the response from the request call.

Will send a list of org-jira-sdk-issue objects to the list printer."
     (org-jira-log "Received data for org-jira-get-sprint-list-callback.")
     (--> data
          (org-jira-sdk-path it '(sprint))
          (append it nil)               ; convert the conses into a proper list.
          org-jira-sdk-create-issues-from-data-list
          org-jira-get-issues))))


;;;###autoload
(defun org-jira-get-issues (issues)
  "Get list of ISSUES into an org buffer.

Default is get unfinished issues assigned to you, but you can
customize jql with a prefix argument.
See`org-jira-get-issue-list'"
  ;; If the user doesn't provide a default, async call to build an issue list
  ;; from the JQL style query
  (interactive
   (org-jira-get-issue-list org-jira-get-issue-list-callback))
  (org-jira-log "Fetching issues...")
  (when (> (length issues) 0)
    (org-jira--render-issues-from-issue-list issues)))

(defvar org-jira-original-default-jql nil)

(defun org-jira-get-issues-from-custom-jql-callback (filename list)
  "Generate a function that can iterate over FILENAME and LIST after callback."
  (cl-function
   (lambda (&key data &allow-other-keys)
     "Callback for async, DATA is the response from the request call.

Will send a list of org-jira-sdk-issue objects to the list printer."
     (org-jira-log
      "Received data for org-jira-get-issues-from-custom-jql-callback.")
     (--> data
          (org-jira-sdk-path it '(issues))
          (append it nil)       ; convert the conses into a proper list.
          (org-jira-sdk-create-issues-from-data-list-with-filename filename it)
          org-jira-get-issues)
     (setq org-jira-proj-key-override nil)
     (let ((next (cdr list)))
       (when next
         (org-jira-get-issues-from-custom-jql next))))))

;;;###autoload
(defun org-jira-get-issues-from-custom-jql (&optional jql-list)
  "Get JQL-LIST list of issues from a custom JQL and PROJ-KEY.

The PROJ-KEY will act as the file name, while the JQL will be any
valid JQL to populate a file to store PROJ-KEY results in.

Please note that this is *not* concurrent or race condition
proof.  If you try to run multiple calls to this function, it
will mangle things badly, as they rely on globals DEFAULT-JQL and
ORG-JIRA-PROJ-KEY-OVERRIDE being set before and after running."
  (interactive)
  (let* ((jl (or jql-list org-jira-custom-jqls))
         (uno (car jl))
         (filename (cl-getf uno :filename))
         (limit (cl-getf uno :limit))
         (jql (replace-regexp-in-string "[\n]" " " (cl-getf uno :jql))))
    (setq org-jira-proj-key-override filename)
    (jiralib-do-jql-search jql limit (org-jira-get-issues-from-custom-jql-callback filename jl))))

(defun org-jira--get-project-buffer (Issue)
  "Open and return the project buffer for a given JIRA ISSUE.

Argument ISSUE is the issue for which the project buffer needs to be retrieved."
  (let* ((proj-key (org-jira--get-proj-key-from-issue Issue))
         (project-file (org-jira--get-project-file-name proj-key))
         (project-buffer (find-file-noselect project-file)))
    project-buffer))

(defun org-jira--is-top-headline? (proj-key)
  "For PROJ-KEY, check if it is a top headline or not."
  (let ((elem (org-element-at-point)))
    (and (eq 'headline (car elem))
         (equal (format "%s-Tickets" proj-key)
                (plist-get (cadr elem) :title))
         (= 1 (plist-get (cadr elem) :level)))))

(defun org-jira--maybe-render-top-heading (proj-key)
  "Ensure that there is a headline for PROJ-KEY at the top of the file."
  (goto-char (point-min))
  (let ((top-heading (format ".*%s-Tickets" proj-key))
        (th-found? nil))
    (while (and (not (eobp))
                (not th-found?))
      (beginning-of-line)
      (when (org-jira--is-top-headline? proj-key) (setq th-found? t))
      (re-search-forward top-heading nil 1 1))
    (beginning-of-line)
    (unless (looking-at top-heading)
      (insert (format "\n* %s-Tickets\n" proj-key)))))

(defun org-jira--render-issue (Issue)
  "Render single ISSUE."
  ;;  (org-jira-log "Rendering issue from issue list")
  ;;  (org-jira-log (org-jira-sdk-dump Issue))
  (with-slots (filename proj-key issue-id summary status priority headline id)
      Issue
    (let (p)
      (with-current-buffer (org-jira--get-project-buffer Issue)
        (org-jira-freeze-ui
          (org-jira-maybe-activate-mode)
          (org-jira--maybe-render-top-heading proj-key)
          (setq p (org-find-entry-with-id issue-id))
          (save-restriction
            (if (and p (>= p (point-min))
                     (<= p (point-max)))
                (progn
                  (goto-char p)
                  (forward-thing 'whitespace)
                  (org-jira-kill-line))
              (goto-char (point-max))
              (unless (looking-at "^")
                (insert "\n"))
              (insert "** "))
            (org-jira-insert
             (concat (org-jira-get-org-keyword-from-status status)
                     " "
                     (org-jira-get-org-priority-cookie-from-issue priority)
                     headline))
            (save-excursion
              (unless (search-forward "\n" (point-max) 1)
                (insert "\n")))
            (org-narrow-to-subtree)
            (save-excursion
              (org-back-to-heading t)
              (org-set-tags (replace-regexp-in-string "-" "_" issue-id)))
            (org-jira-entry-put (point) "assignee" (or (slot-value Issue
                                                                   'assignee) "Unassigned"))
            (mapc (lambda (entry)
                    (let ((val (slot-value Issue entry)))
                      (when (and val (not (string= val "")))
                        (org-jira-entry-put (point)
                                            (symbol-name entry) val))))
                  '(filename reporter type type-id priority labels resolution
                             status components created updated sprint))
            (org-jira-entry-put (point) "ID" issue-id)
            (org-jira-entry-put (point) "CUSTOM_ID" issue-id)

;; Insert the duedate as a deadline if it exists
            (when org-jira-deadline-duedate-sync-p
              (let ((duedate (oref Issue duedate)))
                (when (> (length duedate) 0)
                  (org-deadline nil duedate))))
            (mapc
             (lambda (heading-entry)
               (org-jira-ensure-on-issue-id-with-filename issue-id filename
                                                 (let*
                                                     ((entry-heading
                                                       (concat (symbol-name
                                                                heading-entry)
                                                               (format
                                                                ": [[%s][%s]]"
                                                                (concat
                                                                 jiralib-url
                                                                 "/browse/"
                                                                 issue-id)
                                                                issue-id))))
                                                   (setq p (org-find-exact-headline-in-buffer entry-heading))
                                                   (if (and p (>= p (point-min))
                                                            (<= p (point-max)))
                                                       (progn
                                                         (goto-char p)
                                                         (org-narrow-to-subtree)
                                                         (goto-char (point-min))
                                                         (forward-line 1)
                                                         (delete-region (point)
                                                                        (point-max)))
                                                     (if (org-goto-first-child)
                                                         (org-insert-heading)
                                                       (goto-char (point-max))
                                                       (org-insert-subheading t))
                                                     (org-jira-insert
                                                      entry-heading "\n"))

;;  Insert 2 spaces of indentation so Jira markup won't cause org-markup
                                                   (org-jira-insert
                                                    (replace-regexp-in-string
                                                     "^" "  "
                                                     (format "%s" (slot-value
                                                                   Issue heading-entry)))))))
             '(description))
            (when org-jira-download-comments
              (org-jira-update-comments-for-issue Issue)

;; FIXME: Re-enable when attachments are not erroring.
;;(org-jira-update-attachments-for-current-issue)
              )

;; only sync worklog clocks when the user sets it to be so.
            (when org-jira-worklog-sync-p
              (org-jira-update-worklogs-for-issue issue-id filename))))))))

(defun org-jira--render-issues-from-issue-list (Issues)
  "Add the issues from ISSUES list into the org file(s).

ISSUES is a list of variable `org-jira-sdk-issue' records."
  ;; FIXME: Some type of loading error - the car async callback does not know about
  ;; the issues existing as a class, so we may need to instantiate here if we have none.
  (when (eq 0 (->> Issues (cl-remove-if-not #'org-jira-sdk-isa-issue?) length))
    (setq Issues (org-jira-sdk-create-issues-from-data-list Issues)))

  ;; First off, we never ever want to run on non-issues, so check our types early.
  (setq Issues (cl-remove-if-not #'org-jira-sdk-isa-issue? Issues))
  (org-jira-log (format "About to render %d issues." (length Issues)))

  ;; If we have any left, we map over them.
  (mapc #'org-jira--render-issue Issues)

  ;; Prior text: "Oh, are you the culprit?" - Not sure if this caused an issue at some point.
  ;; We want to ensure we fix broken org narrowing though, by doing org-show-all and then org-cycle.
  (switch-to-buffer (org-jira--get-project-buffer (-last-item Issues)))
  (org-fold-show-all)
  (org-cycle))

;;;###autoload
(defun org-jira-update-comment ()
  "Update a comment for the current issue."
  (interactive)
  (let* ((issue-id (org-jira-get-from-org 'issue 'key)) ; Really the key
         (filename (org-jira-filename))
         (comment-id (org-jira-get-from-org 'comment 'id))
         (comment (replace-regexp-in-string "^  " "" (org-jira-get-comment-body
                                                      comment-id))))
    (let ((issue-id issue-id)
          (filename filename))
      (let ((callback-edit
             (cl-function
              (lambda (&key _data &allow-other-keys)
                (org-jira-ensure-on-issue-id-with-filename
                    issue-id filename
                    (org-jira-update-comments-for-current-issue)))))
            (callback-add
             (cl-function
              (lambda (&key _data &allow-other-keys)
                (org-jira-ensure-on-issue-id-with-filename
                    issue-id filename
                    ;; @TODO :optim: Has to be a better way to do this
                    ;; than delete region (like update the unmarked
                    ;; one)
                    (org-jira-delete-current-comment)
                    (org-jira-update-comments-for-current-issue))))))
        (if comment-id
            (jiralib-edit-comment issue-id comment-id comment callback-edit)
          (jiralib-add-comment issue-id comment callback-add))))))

;;;###autoload
(defun org-jira-add-comment (issue-id filename comment)
  "For ISSUE-ID in FILENAME, add a new COMMENT string to the issue region."
  (interactive
   (let* ((issue-id (org-jira-get-from-org 'issue 'id))
          (filename (org-jira-filename))
          (comment (read-string (format  "Comment (%s): " issue-id))))
     (list issue-id filename comment)))
  (let ((issue-id issue-id)
        (filename filename))
    (org-jira-ensure-on-issue-id-with-filename issue-id filename
                                      (goto-char (point-max))
                                      (jiralib-add-comment
                                       issue-id comment
                                       (cl-function
                                        (lambda (&key _data &allow-other-keys)
                                          (org-jira-ensure-on-issue-id-with-filename issue-id filename
                                                                            (org-jira-update-comments-for-current-issue))))))))

(defun org-jira-org-clock-to-date (org-time)
  "Convert ORG-TIME formatted date into a plain date string."
  (format-time-string
   "%Y-%m-%dT%H:%M:%S.000%z"
   (date-to-time org-time)))

(defun org-jira-worklog-time-from-org-time (org-time)
  "Take in an ORG-TIME and convert it into the portions of a worklog time.
Expects input in format such as:
[2017-04-05 Wed 01:00]--[2017-04-05 Wed 01:46] =>  0:46"
  (let ((start (replace-regexp-in-string "^\\[\\(.*?\\)\\].*" "\\1" org-time))
        (end (replace-regexp-in-string ".*--\\[\\(.*?\\)\\].*" "\\1" org-time)))
    `((started . ,(org-jira-org-clock-to-date start))
      (time-spent-seconds . ,(time-to-seconds
                              (time-subtract
                               (date-to-time end)
                               (date-to-time start)))))))

(defun org-jira-org-clock-to-jira-worklog (org-time clock-content)
  "Given ORG-TIME and CLOCK-CONTENT, format a jira worklog entry."
  (let ((lines (split-string clock-content "\n"))
        worklog-id)
        ;; See if we look like we have an id
    (when (string-match ":id:" (car lines))
      (setq worklog-id
            (replace-regexp-in-string "^.*:id: \\([0-9]*\\)$" "\\1" (car lines)))
      (when (> (string-to-number worklog-id) 0) ;; pop off the car id line if we found it valid
        (setq lines (cdr lines))))
    (setq lines (reverse (cdr (reverse lines)))) ;; drop last line
    (let ((comment (org-trim (mapconcat #'identity lines "\n")))
          (worklog-time (org-jira-worklog-time-from-org-time org-time)))
      `((worklog-id . ,worklog-id)
        (comment . ,comment)
        (started . ,(cdr (assoc 'started worklog-time)))
        (time-spent-seconds . ,(cdr (assoc 'time-spent-seconds worklog-time)))))))

(defun org-jira-worklog-to-hashtable (issue-id)
  "Given ISSUE-ID, return a hashtable of worklog-id -> jira worklog."
  (let ((worklog-hashtable (make-hash-table :test 'equal)))
    (mapc
     (lambda (worklog)
       (let ((worklog-id (cdr (assoc 'id worklog))))
         (puthash worklog-id worklog worklog-hashtable)))
     (jiralib-worklog-import--filter-apply
      (org-jira-find-value
       (jiralib-get-worklogs
        issue-id)
       'worklogs)))
    worklog-hashtable))

;;;###autoload
(defun org-jira-update-worklogs-from-org-clocks ()
  "Update or add a worklog based on the org clocks."
  (interactive)
  (let* ((issue-id (org-jira-get-from-org 'issue 'key))
         (filename (org-jira-filename))
         ;; Fetch all workflogs for this issue
         (jira-worklogs-ht (org-jira-worklog-to-hashtable issue-id)))
    (org-jira-log (format "About to sync worklog for issue: %s in file: %s"
                  issue-id filename))
    (org-jira-ensure-on-issue-id-with-filename issue-id filename
      (search-forward (format ":%s:" (or (org-clock-drawer-name) "LOGBOOK"))  nil 1 1)
      (org-beginning-of-line)
      ;; (org-cycle 1)
      (while (search-forward "CLOCK: " nil 1 1)
        (let ((org-time (buffer-substring-no-properties (point) (line-end-position))))
          (forward-line)
          ;; See where the stuff ends (what point)
          (let (next-clock-point)
            (save-excursion
              (search-forward-regexp "\\(CLOCK\\|:END\\):" nil 1 1)
              (setq next-clock-point (point)))
            (let ((clock-content
                   (buffer-substring-no-properties (point) next-clock-point)))
              ;; Update via jiralib call
              (let* ((worklog (org-jira-org-clock-to-jira-worklog org-time clock-content))
                     (comment-text (cdr (assoc 'comment worklog)))
                     (comment-text (if (string= (org-trim comment-text) "") nil comment-text)))
                (if (cdr (assoc 'worklog-id worklog))
                    ;; If there is a worklog in jira for this ID, check if the worklog has changed.
                    ;; If it has changed, update the worklog.
                    ;; If it has not changed, skip.
                    (let ((jira-worklog (gethash (cdr (assoc 'worklog-id worklog)) jira-worklogs-ht)))
                      (when (and jira-worklog
                                 ;; Check if the entries are differing lengths.
                                 (or (not (= (cdr (assoc 'timeSpentSeconds jira-worklog))
                                         (cdr (assoc 'time-spent-seconds worklog))))
                                 ;; Check if the entries start at different times.
                                     (not (string= (cdr (assoc 'started jira-worklog))
                                               (cdr (assoc 'started worklog))))))
                        (jiralib-update-worklog
                         issue-id
                         (cdr (assoc 'worklog-id worklog))
                         (cdr (assoc 'started worklog))
                         (cdr (assoc 'time-spent-seconds worklog))
                         comment-text
                         nil))) ; no callback - synchronous
                  
                  (jiralib-add-worklog
                   issue-id
                   (cdr (assoc 'started worklog))
                   (cdr (assoc 'time-spent-seconds worklog))
                   comment-text
                   nil)))))))
      (org-jira-log (format "Updating worklog from org-jira-update-worklogs-from-org-clocks call"))
      (org-jira-update-worklogs-for-issue issue-id filename))))

;;;###autoload
(defun org-jira-update-worklog ()
  "Update a worklog for the current issue."
  (interactive)
  (error "Deprecated, use org-jira-update-worklogs-from-org-clocks instead!")
  (let* ((issue-id (org-jira-get-from-org 'issue 'key))
         (worklog-id (org-jira-get-from-org 'worklog 'id))
         (timeSpent (org-jira-get-from-org 'worklog 'timeSpent))
         (timeSpent (if timeSpent
                        timeSpent
                      (read-string
                       "Input the time you spent (such as 3w 1d 2h): ")))
         (timeSpent (replace-regexp-in-string " \\(\\sw\\)\\sw*\\(,\\|$\\)"
                                              "\\1" timeSpent))
         (startDate (org-jira-get-from-org 'worklog 'startDate))
         (startDate (if startDate
                        startDate
                      (org-read-date nil nil nil "Input when did you start")))
         (startDate (org-jira-time-format-to-jira startDate))
         (comment (replace-regexp-in-string "^  " "" (org-jira-get-worklog-comment
                                                      worklog-id))))
    (if worklog-id
        (jiralib-update-worklog issue-id worklog-id
                                startDate timeSpent comment)
      (jiralib-add-worklog-and-autoadjust-remaining-estimate issue-id startDate
                                                             timeSpent comment))
    (org-jira-delete-current-worklog)
    (org-jira-update-worklogs-for-current-issue)))

(defun org-jira-delete-current-comment ()
  "Delete the current comment."
  (org-jira-ensure-on-comment
   (delete-region (point-min) (point-max))))

(defun org-jira-delete-current-worklog ()
  "Delete the current worklog."
  (org-jira-ensure-on-worklog
   (delete-region (point-min) (point-max))))

;;;###autoload
(defun org-jira-copy-current-issue-key ()
  "Copy the current issue's key into clipboard."
  (interactive)
  (let ((issue-id (org-jira-get-from-org 'issue 'key)))
    (with-temp-buffer
      (insert issue-id)
      (kill-region (point-min) (point-max)))))

(defun org-jira-get-comment-id (comment)
  "Get the ID of a JIRA COMMENT.

Argument COMMENT is the comment object from which the ID will be extracted."
  (org-jira-find-value comment 'id))

(defun org-jira-get-comment-author (comment)
  "Get the author of a Jira COMMENT.

Argument COMMENT is the comment for which the author's display name is to be
retrieved."
  (org-jira-find-value comment 'author 'displayName))

(defun org-jira-isa-ignored-comment? (comment)
  "Check if a COMMENT is ignored in `org-jira'.

Argument COMMENT is the comment object that needs to be checked if it is ignored
or not."
  (member-ignore-case (oref comment author) org-jira-ignore-comment-user-list))

(defun org-jira-maybe-reverse-comments (comments)
  "Reverse COMMENTS if `org-jira-reverse-comment-order' is true.

Argument COMMENTS is a list of comments."
  (if org-jira-reverse-comment-order (reverse comments) comments))

(defun org-jira-extract-comments-from-data (data)
  "Extract comments from DATA.

Argument DATA is a list of data that contains comments."
  (->> (append data nil)
       org-jira-sdk-create-comments-from-data-list
       org-jira-maybe-reverse-comments
       (cl-remove-if #'org-jira-isa-ignored-comment?)))

(defun org-jira--render-comment (Issue Comment)
  "Render a COMMENT for ISSUE.

Argument COMMENT is an object that represents a comment in Jira."
  (with-slots (issue-id) Issue
    (with-slots (comment-id author headline created updated body) Comment
      (org-jira-log (format "Rendering a comment: %s" body))
      (org-jira-ensure-on-issue-Issue Issue
        (setq p (org-find-entry-with-id comment-id))
        (when (and p (>= p (point-min))
                   (<= p (point-max)))
          (goto-char p)
          (org-narrow-to-subtree)
          (delete-region (point-min) (point-max)))
        (goto-char (point-max))
        (unless (looking-at "^")
          (insert "\n"))
        (insert "*** ")
        (org-jira-insert headline "\n")
        (org-narrow-to-subtree)
        (org-jira-entry-put (point) "ID" comment-id)
        (org-jira-entry-put (point) "created" created)
        (unless (string= created updated)
          (org-jira-entry-put (point) "updated" updated))
        (goto-char (point-max))
        ;;  Insert 2 spaces of indentation so Jira markup won't cause org-markup
        (org-jira-insert (replace-regexp-in-string "^" "  " (or body "")))))))

(defun org-jira-update-comments-for-issue (Issue)
  "Update the comments for the specified ISSUE issue."
  (let* ((object Issue))
    (jiralib-get-comments
     (slot-value object 'issue-id)
     (lambda
       (&rest request-response)
       (let ((cb-data
              (cl-getf request-response :data)))
         (org-jira-log
          "In the callback for org-jira-update-comments-for-issue.")
         (let ((it
                (org-jira-find-value cb-data 'comments)))
           (let ((it
                  (org-jira-extract-comments-from-data it)))
             (mapc
              #'(lambda
                  (Comment)
                  (org-jira--render-comment Issue Comment))
              it))))))))

(defun org-jira-update-comments-for-current-issue ()
  "Update comments for the current issue."
  (org-jira-log "About to update comments for current issue.")
  (let ((Issue (make-instance 'org-jira-sdk-issue
                              :issue-id (org-jira-get-from-org 'issue 'key)
                              :filename (org-jira-filename))))
    (-> Issue org-jira-update-comments-for-issue)))

(defun org-jira-delete-subtree ()
  "Derived from `org-cut-subtree'.

Like that function, without mangling the user's clipboard for the
purpose of wiping an old subtree."
  (let (beg end folded (beg0 (point)))
    (org-back-to-heading t)     ; take what is really there
    (setq beg (point))
    (skip-chars-forward " \t\r\n")
    (save-match-data
      (save-excursion
        (outline-end-of-heading)
        (setq folded (org-invisible-p))
        (org-end-of-subtree t t)))
        ;; Include the end of an inlinetask
    (when (and
           (require 'org-inlinetask nil t)
           (featurep 'org-inlinetask)
           (fboundp 'org-inlinetask-outline-regexp)
           (looking-at-p (concat (org-inlinetask-outline-regexp)
                                 "END[ \t]*$")))
      (end-of-line))
    (setq end (point))
    (goto-char beg0)
    (when (> end beg)
      (setq org-subtree-clip-folded folded)
      (org-save-markers-in-region beg end)
      (delete-region beg end))))

(defun org-jira-update-attachments-for-current-issue ()
  "Update the attachments for the current issue."
  (when jiralib-use-restapi
    (let ((issue-id (org-jira-get-from-org 'issue 'key)))
    ;; Run the call
                 (jiralib-get-attachments
                  issue-id
                  (save-excursion
                    (cl-function
                     (lambda (&key data &allow-other-keys)
                     ;; First, make sure we're in the proper buffer (logic copied from org-jira-get-issues.
                       (let* ((proj-key (replace-regexp-in-string "-.*" ""
                                                                  issue-id))
                              (project-file (org-jira--get-project-file-name
                                             proj-key))
                              (project-buffer (or (find-buffer-visiting
                                                   project-file)
                                                  (find-file project-file))))
                         (with-current-buffer project-buffer
                         ;; delete old attachment node
                           (org-jira-ensure-on-issue
                             (if (org-goto-first-child)
                                 (while (org-goto-sibling)
                                   (forward-thing 'whitespace)
                                   (when (looking-at "Attachments:")
                                     (org-jira-delete-subtree)))))
                           (let
                               ((attachments
                                 (org-jira-find-value data 'fields 'attachment)))
                             (when (not (zerop (length attachments)))
                               (org-jira-ensure-on-issue
                                 (if (org-goto-first-child)
                                     (progn
                                       (while (org-goto-sibling))
                                       (org-insert-heading-after-current))
                                   (org-insert-subheading nil))
                                 (insert "Attachments:")
                                 (mapc
                                  (lambda (attachment)
                                    (let
                                        ((attachment-id (org-jira-get-comment-id
                                                         attachment))
                                         (author (org-jira-get-comment-author
                                                  attachment))
                                         (created
                                          (org-jira-transform-time-format
                                           (org-jira-find-value
                                            attachment
                                            'created)))
                                         (size (org-jira-find-value attachment
                                                                    'size))
                                         (content
                                          (org-jira-find-value attachment
                                                               'content))
                                         (filename
                                          (org-jira-find-value
                                           attachment
                                           'filename)))
                                      (if (looking-back "Attachments:" 0)
                                          (org-insert-subheading nil)
                                        (org-insert-heading-respect-content))
                                      (insert "[[" content "][" filename "]]")
                                      (org-narrow-to-subtree)
                                      (org-jira-entry-put (point) "ID"
                                                          attachment-id)
                                      (org-jira-entry-put (point) "Author"
                                                          author)
                                      (org-jira-entry-put (point) "Name"
                                                          filename)
                                      (org-jira-entry-put (point) "Created"
                                                          created)
                                      (org-jira-entry-put (point) "Size"
                                                          (ls-lisp-format-file-size
                                                           size t))
                                      (org-jira-entry-put (point) "Content"
                                                          content)
                                      (widen)))
                                  attachments)))))))))))))

(defun org-jira-sort-org-clocks (clocks)
  "Given a CLOCKS list, sort it by start date descending."
  ;; Expects data such as this:

  ;; ((\"2017-02-26 Sun 00:08\" \"2017-02-26 Sun 01:08\" \"Hi\" \"10101\")
  ;;  (\"2017-03-16 Thu 22:25\" \"2017-03-16 Thu 22:57\" \"Test\" \"10200\"))
  (sort clocks
        (lambda (a b)
          (> (time-to-seconds (date-to-time (car a)))
             (time-to-seconds (date-to-time (car b)))))))

(defun org-jira-update-worklogs-for-current-issue ()
  "Update the worklogs for the current issue."
  (let ((issue-id (org-jira-get-from-org 'issue 'key))
        (filename (org-jira-filename)))
    (org-jira-update-worklogs-for-issue issue-id filename)))

(defun org-jira-update-worklogs-for-issue (issue-id filename)
  "Update the worklogs for the current ISSUE-ID located in FILENAME."
  (org-jira-log (format "org-jira-update-worklogs-for-issue id: %s filename: %s"
                issue-id filename))
  ;; Run the call
  (jiralib-get-worklogs
   issue-id
   (org-jira-with-callback
     (org-jira-ensure-on-issue-id-with-filename issue-id filename
       (let ((worklogs (org-jira-find-value cb-data 'worklogs)))
         (org-jira-log (format "org-jira-update-worklogs-for-issue cb id: %s fn: %s"
                       issue-id filename))
         (org-jira-logbook-reset issue-id filename
          (org-jira-sort-org-clocks (org-jira-worklogs-to-org-clocks
                                     (jiralib-worklog-import--filter-apply worklogs)))))))))

;;;###autoload
(defun org-jira-unassign-issue ()
  "Update an issue to be unassigned."
  (interactive)
  (let ((issue-id (org-jira-parse-issue-id))
        (filename (org-jira-parse-issue-filename)))
    (org-jira-update-issue-details issue-id filename :assignee nil)))

;;;###autoload
(defun org-jira-set-issue-reporter ()
  "Update an issue's reporter interactively."
  (interactive)
  (let ((issue-id (org-jira-parse-issue-id))
        (filename (org-jira-parse-issue-filename)))
    (if issue-id
        (let* ((project (replace-regexp-in-string "-[0-9]+" "" issue-id))
               (jira-users (org-jira-get-reporter-candidates project)) ;; TODO, probably a better option than org-jira-get-assignable-users here
               (user (completing-read
                      "Reporter: "
                      (append (mapcar #'car jira-users)
                              (mapcar #'cdr jira-users))))
               (reporter (or
                          (cdr (assoc user jira-users))
                          (cdr (rassoc user jira-users)))))
          (when (null reporter)
            (error "No reporter found, this should probably never happen"))
          (org-jira-update-issue-details issue-id filename :reporter (jiralib-get-user-account-id
                                                                      project reporter)))
      (error "Not on an issue"))))

;;;###autoload
(defun org-jira-assign-issue ()
  "Update an issue with interactive re-assignment."
  (interactive)
  (let ((issue-id (org-jira-parse-issue-id))
        (filename (org-jira-parse-issue-filename)))
    (if issue-id
        (let* ((project (replace-regexp-in-string "-[0-9]+" "" issue-id))
               (jira-users (org-jira-get-assignable-users project))
               (user (completing-read
                      "Assignee: "
                      (append (mapcar #'car jira-users)
                              (mapcar #'cdr jira-users))))
               (assignee (or
                          (cdr (assoc user jira-users))
                          (cdr (rassoc user jira-users)))))
          (when (null assignee)
            (error "No assignee found, use org-jira-unassign-issue to make the issue unassigned"))
          (org-jira-update-issue-details issue-id filename :assignee (jiralib-get-user-account-id project assignee)))
      (error "Not on an issue"))))

;;;###autoload
(defun org-jira-update-issue ()
  "Update an issue."
  (interactive)
  (let ((issue-id (org-jira-parse-issue-id))
        (filename (org-jira-parse-issue-filename)))
    (if issue-id
        (org-jira-update-issue-details issue-id filename)
      (error "Not on an issue"))))

;;;###autoload
(defun org-jira-todo-to-jira ()
  "Convert an ordinary todo item to a jira ticket."
  (interactive)
  (org-jira-ensure-on-todo
   (when (org-jira-parse-issue-id)
     (error "Already on jira ticket"))
   (save-excursion (org-jira-create-issue
                    (org-jira-read-project)
                    (org-jira-read-issue-type)
                    (org-get-heading t t)
                    (org-get-entry)))
   (delete-region (point-min) (point-max))))

;;;###autoload
(defun org-jira-get-subtasks ()
  "Get subtasks for the current issue."
  (interactive)
  (org-jira-ensure-on-issue
    (org-jira-get-issues-headonly (jiralib-do-jql-search (format "parent = %s" (org-jira-parse-issue-id))))))

(defvar org-jira-project-read-history nil)
(defvar org-jira-boards-read-history nil)
(defvar org-jira-sprints-read-history nil)
(defvar org-jira-components-read-history nil)
(defvar org-jira-priority-read-history nil)
(defvar org-jira-type-read-history nil)

(defun org-jira-read-project ()
  "Read project name."
  (completing-read
   "Project: "
   (jiralib-make-list (jiralib-get-projects) 'key)
   nil
   t
   nil
   'org-jira-project-read-history
   (car org-jira-project-read-history)))

(defun org-jira-read-board ()
  "Read board name and return cons pair (name . integer-id)."
  (let* ((boards-alist
          (jiralib-make-assoc-list (jiralib-get-boards) 'name 'id))
         (board-name
          (completing-read "Boards: "  boards-alist
                           nil  t  nil
                           'org-jira-boards-read-history
                           (car org-jira-boards-read-history))))
    (assoc board-name boards-alist)))

(defun org-jira-read-sprint (board)
  "Prompt user to select a sprint from a list.

Argument BOARD is the board from which the sprints will be retrieved."
  (let* ((sprints-alist
          (jiralib-make-assoc-list (append (alist-get 'values
                                                      (jiralib-get-board-sprints
                                                       board))
                                           nil)
                                   'name 'id))
         (sprint-name
          (completing-read "Sprints: " sprints-alist
                           nil t nil
                           'org-jira-sprints-read-history
                           (car org-jira-sprints-read-history))))
    (assoc sprint-name sprints-alist)))

(defun org-jira-read-component (project)
  "Read the components options for PROJECT such as EX."
  (completing-read
   "Components (choose Done to stop): "
   (append '("Done") (mapcar #'cdr (jiralib-get-components project)))
   nil
   t
   nil
   'org-jira-components-read-history
   "Done"))

;; TODO: Finish this feature - integrate into org-jira-create-issue
(defun org-jira-read-components (project)
  "Types: string PROJECT : string (csv of components).

Get all the components for the PROJECT such as EX,
that should be bound to an issue."
  (let (components component)
    (while (not (equal "Done" component))
      (setq component (org-jira-read-component project))
      (unless (equal "Done" component)
        (push component components)))
    components))

(defun org-jira-read-priority ()
  "Read priority name."
  (completing-read
   "Priority: "
   (mapcar #'cdr (jiralib-get-priorities))
   nil
   t
   nil
   'org-jira-priority-read-history
   (car org-jira-priority-read-history)))

(defun org-jira-read-issue-type (&optional project)
  "Read issue type name.  PROJECT is the optional project key."
  (let* ((issue-types
          (mapcar #'cdr (if project
                           (jiralib-get-issue-types-by-project project)
                         (jiralib-get-issue-types))))
         (initial-input (when (member (car org-jira-type-read-history) issue-types)
                          org-jira-type-read-history)))

    ;; TODO: The completing-read calls as such are all over the place, and always tend
    ;; to follow this exact same call structure - we should abstract to a single fn
    ;; that will allow calling with fewer or keyword args
    (completing-read
     "Type: "                           ; PROMPT
     issue-types                        ; COLLECTION
     nil                                ; PREDICATE
     t                                  ; REQUIRE-MATCH
     nil                                ; INITIAL-INPUT
     'initial-input                     ; HIST
     (car initial-input))))             ; DEF

(defun org-jira-read-subtask-type ()
  "Read issue type name."
  (completing-read
   "Type: "
   (mapcar #'cdr (jiralib-get-subtask-types))
   nil
   t
   nil
   'org-jira-type-read-history
   (car org-jira-type-read-history)))

(defun org-jira-get-issue-struct (project type summary description &optional
                                          parent-id)
  "Create JIRA issue struct with provided information.

Argument PARENT-ID is an optional argument that represents the ID of the parent
issue if the current issue is a subtask.
Argument DESCRIPTION is a required argument that represents the DESCRIPTION of
the issue.
Argument SUMMARY is a required argument that represents the SUMMARY or title of
the issue.
Argument TYPE is a required argument that represents the TYPE of the issue.
Argument PROJECT is a required argument that represents the PROJECT to which the
issue belongs."
  (if (or (equal project "")
          (equal type "")
          (equal summary ""))
      (error "Must provide all information!"))
  (let* ( ;; (project-components (jiralib-get-components project))
         (jira-users (org-jira-get-assignable-users project))
         (user (completing-read "Assignee: " (mapcar #'car jira-users)))
         (priority (car (rassoc (org-jira-read-priority)
                                (jiralib-get-priorities))))
         (ticket-struct
          `((fields
             (project (key . ,project))
             (parent (key . ,parent-id))
             (issuetype (id . ,(car (rassoc type (if (and (boundp 'parent-id)
                                                          parent-id)
                                                     (jiralib-get-subtask-types)
                                                   (jiralib-get-issue-types-by-project
                                                    project))))))
             (summary . ,(format "%s%s" summary
                                 (if (and (boundp 'parent-id) parent-id)
                                     (format " (subtask of [jira:%s])" parent-id)
                                   "")))
             (description . ,description)
             (priority (id . ,priority))
             ;; accountId should be nil if Unassigned, not the key slot.
             (assignee (accountId . ,(or (cdr (assoc user jira-users)) nil)))))))
    ticket-struct))

;;;###autoload
(defun org-jira-create-issue (project type summary description)
  "Create an issue in PROJECT, of type TYPE, with given SUMMARY and DESCRIPTION."
  (interactive
   (let* ((project (org-jira-read-project))
          (type (org-jira-read-issue-type project))
          (summary (read-string "Summary: "))
          (description (read-string "Description: ")))
     (list project type summary description)))
  (if (or (equal project "")
          (equal type "")
          (equal summary ""))
      (error "Must provide all information!"))
  (let* ((parent-id nil)
         (ticket-struct (org-jira-get-issue-struct project type summary
                                                   description
                                                   parent-id)))
    (org-jira-get-issues (list (jiralib-create-issue ticket-struct)))))

;;;###autoload
(defun org-jira-create-subtask (project type summary description)
  "Create a subtask issue for PROJECT, of TYPE, with SUMMARY and DESCRIPTION."
  (interactive (org-jira-ensure-on-issue (list (org-jira-read-project)
                                      (org-jira-read-subtask-type)
                                      (read-string "Summary: ")
                                      (read-string "Description: "))))
  (if (or (equal project "")
          (equal type "")
          (equal summary ""))
      (error "Must provide all information!"))
  (let* ((parent-id (org-jira-parse-issue-id))
         (ticket-struct (org-jira-get-issue-struct project type summary description parent-id)))
    (org-jira-get-issues (list (jiralib-create-subtask ticket-struct)))))

(defun org-jira-get-issue-val-from-org (key)
  "Return the requested value by KEY from the current issue."
  ;; There is some odd issue when not using any let-scoping, where myself
  ;; and an array of users are hitting a snag circa 2023-03-01 time frame
  ;; in which the setq portion of a when clause is being hit even when it
  ;; evaluates to false - the bug only manifests on a car launch of Emacs - it
  ;; doesn't occur when re-evaluating this function.  However, wrapping it "fixes"
  ;; the issue.
  ;;
  ;; The car link has the most troubleshooting/diagnosis around the particulars of
  ;; this bug.
  ;;
  ;; See: https://github.com/ahungry/org-jira/issues/319
  ;; See: https://github.com/ahungry/org-jira/issues/296
  ;; See: https://github.com/ahungry/org-jira/issues/316
  (let ((my-key key))
    (org-jira-ensure-on-issue
      (cond ((eq my-key 'description)
             (org-goto-first-child)
             (forward-thing 'whitespace)
             (if (looking-at "description: ")
                 (org-trim (org-get-entry))
               (error "Can not find description field for this issue")))
            ((eq my-key 'summary)
             (org-jira-ensure-on-issue
               (org-get-heading t t)))

;; org returns a time tuple, we need to convert it
            ((eq my-key 'deadline)
             (let ((encoded-time (org-get-deadline-time (point))))
               (when encoded-time
                 (cl-reduce (lambda (carry segment)
                              (format "%s-%s" carry segment))
                            (reverse (cl-subseq (decode-time encoded-time) 3 6))))))

;; default case, just grab the value in the properties block
            (t
             (when (symbolp my-key)
               (setq my-key (symbol-name my-key)))
             (setq my-key (or (assoc-default my-key org-jira-property-overrides)
                              my-key))

;; This is the "impossible" to hit setq that somehow gets hit without the let
;; wrapper around the function input args.
             (when (string= my-key "key")
               (setq my-key "ID"))

;; The variable `org-special-properties' will mess this up
;; if our search, such as 'priority' is within there, so
;; don't bother with it for this (since we only ever care
;; about the local properties, not any hierarchal or special
;; ones).
             (let ((org-special-properties nil))
               (or (org-entry-get (point) my-key t)
                   "")))))))

(defun org-jira-read-action (actions)
  "Read issue workflow progress ACTIONS."
  (let ((action (completing-read
                 "Action: "
                 (mapcar #'cdr actions)
                 nil
                 t
                 nil)))
    (or
     (car (rassoc action actions))
     (user-error "You specified an empty action, the valid actions are: %s" (mapcar #'cdr actions)))))

(defvar org-jira-fields-history nil)
(defun org-jira-read-field (fields)
  "Read (custom) FIELDS for workflow progress."
  (let ((field-desc (completing-read
                     "More fields to set: "
                     (cons "Thanks, no more fields are *required*." (mapcar #'org-jira-decode (mapcar #'cdr fields)))
                     nil
                     t
                     nil
                     'org-jira-fields-history))
        field-name)
    (setq field-name (car (rassoc field-desc fields)))
    (if field-name
        (intern field-name)
      field-name)))


(defvar org-jira-rest-fields nil
  "Extra fields are held here for usage between two endpoints.
Used in `org-jira-read-resolution' and `org-jira-progress-issue' calls.")

(defvar org-jira-resolution-history nil)
(defun org-jira-read-resolution ()
  "Read issue workflow progress resolution."
  (if (not jiralib-use-restapi)
      (let ((resolution (completing-read
                         "Resolution: "
                         (mapcar #'cdr (jiralib-get-resolutions))
                         nil
                         t
                         nil
                         'org-jira-resolution-history
                         (car org-jira-resolution-history))))
        (car (rassoc resolution (jiralib-get-resolutions))))
    (let* ((resolutions (org-jira-find-value org-jira-rest-fields 'resolution 'allowedValues))
           (resolution-name (completing-read
                             "Resolution: "
                             (mapcar (lambda (resolution)
                                       (org-jira-find-value resolution 'name))
                                     resolutions))))
      (cons 'name resolution-name))))

;;;###autoload
(defun org-jira-refresh-issues-in-buffer-loose ()
  "Iterates over 1-2 headings in current buffer, refreshing on issue :ID:.
It differs with org-jira-refresh-issues-in-buffer() in that:
a) It accepts current buffer and its corresponding filename, regardless of
whether it has been previously registered as an org-jira project file or not.
b) It doesn't expect a very specific structure in the org buffer, but simply
goes over every existing heading (level 1-2), and refreshes it IFF a valid
jira ID can be detected in it."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (outline-show-all)
      (outline-hide-sublevels 2)
      (goto-char (point-min))
      (while (not (eobp))
        (progn
          (if (org-jira-id)
              (progn
                (org-jira--refresh-issue (org-jira-id)
                                         (file-name-sans-extension
                                          buffer-file-name))))
          (outline-next-visible-heading 1))))))

;; TODO: Refactor to just scoop all ids from buffer, run org-jira-ensure-on-issue-id on
;; each using a map, and refresh them that way.  That way we don't have to iterate
;; on the user headings etc.
;;;###autoload
(defun org-jira-refresh-issues-in-buffer ()
  "Iterate across all entries in current buffer, refreshing on issue :ID:.
Where issue-id will be something such as \"EX-22\"."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (outline-show-all)
      (outline-hide-sublevels 2)
      (goto-char (point-min))
      (while (and (or (looking-at "^ *$")
                      (looking-at "^#.*$")
                      (looking-at "^\\* .*"))
                  (not (eobp)))
        (forward-line))
      (outline-next-visible-heading 1)
      (while (and (not (org-next-line-empty-p))
                  (not (eobp)))
        (when (outline-on-heading-p t)
          ;; It's possible we could be on a non-org-jira headline, but
          ;; that should be an exceptional case and not necessitating a
          ;; fix atm.
          (org-jira-refresh-issue))
        (outline-next-visible-heading 1)))))

;;;###autoload
(defun org-jira-refresh-issue ()
  "Refresh current issue from jira to org."
  (interactive)
  (org-jira-ensure-on-issue
    (org-jira--refresh-issue (org-jira-id) (org-jira-filename))))

(defun org-jira--refresh-issue (issue-id &optional filename)
  "Refresh issue from jira to org using ISSUE-ID and FILENAME."
  (unless filename
    (setq filename (replace-regexp-in-string "-[0-9]+" "" issue-id)))
  (jiralib-get-issue
   issue-id
   (org-jira-with-callback
     (org-jira-log (format "Received refresh issue data for id: %s in file: %s"
                           issue-id filename))
     (--> cb-data
          list
          (org-jira-sdk-create-issues-from-data-list-with-filename filename it)
          org-jira--render-issues-from-issue-list))))

(defun org-jira--refresh-issue-by-id (issue-id)
  "Refresh issue from jira to org using ISSUE-ID."
  (org-jira-ensure-on-issue-id issue-id
    (org-jira--refresh-issue issue-id)))

(defvar org-jira-fields-values-history nil)
;;;###autoload
(defun org-jira-progress-issue ()
  "Progress issue workflow."
  (interactive)
  (org-jira-ensure-on-issue
    (let* ((issue-id (org-jira-id))
           (actions (jiralib-get-available-actions
                     issue-id
                     (org-jira-get-issue-val-from-org 'status)))
           (action (org-jira-read-action actions))
           (fields (jiralib-get-fields-for-action issue-id action))
           (org-jira-rest-fields fields)
           (field-key)
           (custom-fields-collector nil)
           (custom-fields
            (progn
            ;; delete those elements in fields, which have
            ;; already been set in custom-fields-collector
              (while fields
                (setq fields
                      (cl-remove-if
                       (lambda (strstr)
                         (cl-member-if (lambda (symstr)
                                         (string= (car strstr)  (symbol-name (car symstr))))
                                       custom-fields-collector))
                       fields))
                (setq field-key (org-jira-read-field fields))
                (if (not field-key)
                    (setq fields nil)
                  (setq custom-fields-collector
                        (cons
                         (funcall (if jiralib-use-restapi
                                      #'list
                                    #'cons)
                                  field-key
                                  (if (eq field-key 'resolution)
                                      (org-jira-read-resolution)
                                    (let ((field-value (completing-read
                                                        (format "Please enter %s's value: "
                                                                (cdr (assoc (symbol-name field-key) fields)))
                                                        org-jira-fields-values-history
                                                        nil
                                                        nil
                                                        nil
                                                        'org-jira-fields-values-history)))
                                      (if jiralib-use-restapi
                                          (cons 'name field-value)
                                        field-value))))
                         custom-fields-collector))))
              custom-fields-collector)))
      (jiralib-progress-workflow-action
       issue-id
       action
       custom-fields
       (cl-function
        (lambda (&key _data &allow-other-keys)
          (org-jira-refresh-issue)))))))

(defun org-jira-progress-next-action (actions current-status)
  "Grab the user defined `next' action from ACTIONS, given CURRENT-STATUS."
  (let* ((next-action-name (cdr (assoc current-status
                                       org-jira-progress-issue-flow)))
         (next-action-id (caar (cl-remove-if-not
                                (lambda (action)
                                  (equal action next-action-name))
                                actions :key #'cdr))))
    next-action-id))

;;;###autoload
(defun org-jira-progress-issue-next ()
  "Progress issue workflow."
  (interactive)
  (org-jira-ensure-on-issue
    (let* ((issue-id (org-jira-id))
           (filename (org-jira-filename))
           (actions (jiralib-get-available-actions
                     issue-id
                     (org-jira-get-issue-val-from-org 'status)))
           (action (org-jira-progress-next-action actions (org-jira-get-issue-val-from-org 'status)))
           (fields (jiralib-get-fields-for-action issue-id action))
           (org-jira-rest-fields fields)
           (field-key)
           (custom-fields-collector nil)
           (custom-fields
            (progn
              ;; delete those elements in fields, which have
              ;; already been set in custom-fields-collector
              (while fields
                (setq fields
                      (cl-remove-if
                       (lambda (strstr)
                         (cl-member-if (lambda (symstr)
                                         (string= (car strstr)  (symbol-name (car symstr))))
                                       custom-fields-collector))
                       fields))
                (setq field-key (org-jira-read-field fields))
                (if (not field-key)
                    (setq fields nil)
                  (setq custom-fields-collector
                        (cons
                         (funcall (if jiralib-use-restapi
                                      #'list
                                    #'cons)
                                  field-key
                                  (if (eq field-key 'resolution)
                                      (org-jira-read-resolution)
                                    (let ((field-value (completing-read
                                                        (format "Please enter %s's value: "
                                                                (cdr (assoc (symbol-name field-key) fields)))
                                                        org-jira-fields-values-history
                                                        nil
                                                        nil
                                                        nil
                                                        'org-jira-fields-values-history)))
                                      (if jiralib-use-restapi
                                          (cons 'name field-value)
                                        field-value))))
                         custom-fields-collector))))
              custom-fields-collector)))
      (if action
          (jiralib-progress-workflow-action
           issue-id
           action
           custom-fields
           (org-jira-with-callback
             (org-jira-ensure-on-issue-id-with-filename issue-id filename
               (org-jira-refresh-issue))))
        (error "No action defined for that step!")))))


(defun org-jira-get-id-name-alist (name ids-to-names)
  "Find the id corresponding to NAME in IDS-TO-NAMES.
Return an alist with id and name as keys."
  (let ((id (car (rassoc name ids-to-names))))
    `((id . ,id)
      (name . ,name))))

(defun org-jira-build-components-list (project-components org-issue-components)
  "Given PROJECT-COMPONENTS and ORG-ISSUE-COMPONENTS, attempt to build a list.

If the PROJECT-COMPONENTS are nil, this should return:

  (list components []), which will translate into the JSON:

  {\"components\": []}

otherwise it should return:

  (list components (list (cons id comp-id) (cons name item-name))),

  which will translate into the JSON:

{\"components\": [{\"id\": \"comp-id\", \"name\": \"item\"}]}"
  (if (not project-components)
      (vector) ;; Return a blank array for JSON
    (apply #'list
           (cl-mapcan
            (lambda (item)
              (let ((comp-id (car (rassoc item project-components))))
                (if comp-id
                    `(((id . ,comp-id)
                       (name . ,item)))
                  nil)))
            (split-string org-issue-components ",\\s *")))))

(defun org-jira-strip-priority-tags (s)
  "Given string S, remove any priority tags in the brackets."
  (->> s (replace-regexp-in-string "\\[#.*?\\]" "") org-trim))

(defun org-jira-update-issue-details (issue-id filename &rest rest)
  "Update the details of issue ISSUE-ID in FILENAME.
REST will contain optional input."
  (org-jira-ensure-on-issue-id-with-filename
   issue-id filename
   ;; Set up a bunch of values from the org content
   (let* ((org-issue-components (org-jira-get-issue-val-from-org
                                 'components))
          (org-issue-labels (org-jira-get-issue-val-from-org
                             'labels))
          (org-issue-description
           (org-trim
            (org-jira-get-issue-val-from-org
             'description)))
          (org-issue-priority (org-jira-get-issue-val-from-org
                               'priority))
          (org-issue-type (org-jira-get-issue-val-from-org
                           'type))
          (org-issue-type-id (org-jira-get-issue-val-from-org
                              'type-id))
          (org-issue-assignee
           (cl-getf
            rest :assignee
            (org-jira-get-issue-val-from-org
             'assignee)))
          (org-issue-reporter
           (cl-getf
            rest :reporter
            (org-jira-get-issue-val-from-org
             'reporter)))
          (project (replace-regexp-in-string
                    "-[0-9]+" "" issue-id))
          (project-components (jiralib-get-components
                               project)))

;; Lets fire off a worklog update async with the main issue
;; update, why not?  This is better to fire car, because it
;; doesn't auto-refresh any areas, while the end of the main
;; update does a callback that reloads the worklog entries (so,
;; we hope that wont occur until after this successfully syncs
;; up).  Only do this sync if the user defcustom defines it as such.
     (when org-jira-worklog-sync-p
       (org-jira-update-worklogs-from-org-clocks))

;; Send the update to jira
     (let
         ((update-fields
           (list (cons
                  'components
                  (or
                   (org-jira-build-components-list
                    project-components
                    org-issue-components)
                   []))
                 (cons 'labels (split-string
                                org-issue-labels
                                ",\\s *"))
                 (cons 'priority
                       (org-jira-get-id-name-alist
                        org-issue-priority
                        (jiralib-get-priorities)))
                 (cons 'description
                       org-issue-description)
                 (cons 'assignee
                       (list
                        (cons
                         'id
                         (jiralib-get-user-account-id
                          project
                          org-issue-assignee))))
                 (cons 'reporter
                       (list
                        (cons
                         'id
                         (jiralib-get-user-account-id
                          project
                          org-issue-reporter))))
                 (cons 'summary
                       (org-jira-strip-priority-tags
                        (org-jira-get-issue-val-from-org
                         'summary)))
                 (cons 'issuetype
                       `((id
                          . ,org-issue-type-id)
                         (name
                          .
                          ,org-issue-type))))))


;; If we enable duedate sync and we have a deadline present
       (when (and
              org-jira-deadline-duedate-sync-p
              (org-jira-get-issue-val-from-org
               'deadline))
         (setq update-fields
               (append update-fields
                       (list (cons 'duedate (org-jira-get-issue-val-from-org 'deadline))))))

;; TODO: We need some way to handle things like assignee setting
;; and refreshing the proper issue in the proper buffer/filename.
       (jiralib-update-issue
        issue-id
        update-fields
        ;; This callback occurs on success
        (org-jira-with-callback
          (message (format
                    "Issue '%s' updated!"
                    issue-id))
          (jiralib-get-issue
           issue-id
           (org-jira-with-callback
             (org-jira-log
              "Update get issue for refresh callback hit.")
             (-> cb-data list
                 org-jira-get-issues)))))))))



(defun org-jira-parse-issue-id ()
  "Get issue id from org text."
  (save-excursion
    (let ((continue t)
          issue-id)
      (while continue
        (when (string-match (jiralib-get-issue-regexp)
                            (or (setq issue-id (org-entry-get (point) "ID"))
                                ""))
          (setq continue nil))
        (unless (and continue (org-up-heading-safe))
          (setq continue nil)))
      issue-id)))

(defun org-jira-parse-issue-filename ()
  "Get filename from org text."
  (save-excursion
    (let ((continue t)
          filename)
      (while continue
        (when (setq filename (org-entry-get (point) "filename"))
          (setq continue nil))
        (unless (and continue (org-up-heading-safe))
          (setq continue nil)))
      filename)))

(defun org-jira-get-from-org (type entry)
  "Get an org property from the current item.

TYPE is the type to of the current item, and can be issue, or comment.

ENTRY will vary, and is the name of the property to return. If
it is a symbol, it will be converted to string."
  (when (symbolp entry)
    (setq entry (symbol-name entry)))
  (cond ((eq type 'issue)
         (org-jira-get-issue-val-from-org entry))
        ((eq type 'comment)
         (org-jira-get-comment-val-from-org entry))
        ((eq type 'worklog)
         (org-jira-get-worklog-val-from-org entry))
        (t (error "Unknown type %s" type))))

(defun org-jira-get-comment-val-from-org (entry)
  "Get the JIRA issue field value ENTRY of the current comment item."
  (org-jira-ensure-on-comment
   (when (symbolp entry)
     (setq entry (symbol-name entry)))
   (when (string= entry "id")
     (setq entry "ID"))
   (org-entry-get (point) entry)))

(defun org-jira-get-worklog-val-from-org (entry)
  "Get the JIRA issue field value ENTRY of the current worklog item."
  (org-jira-ensure-on-worklog
   (when (symbolp entry)
     (setq entry (symbol-name entry)))
   (when (string= entry "id")
     (setq entry "ID"))
   (org-entry-get (point) entry)))

(defun org-jira-get-comment-body (&optional comment-id)
  "Get the comment body of the comment with id COMMENT-ID."
  (org-jira-ensure-on-comment
   (goto-char (point-min))
   ;; so that search for :END: won't fail
   (org-jira-entry-put (point) "ID" comment-id)
   (search-forward ":END:" nil 1 1)
   (forward-line)
   (org-trim (buffer-substring-no-properties (point) (point-max)))))

(defun org-jira-get-worklog-comment (&optional worklog-id)
  "Get the worklog comment of the worklog with id WORKLOG-ID."
  (org-jira-ensure-on-worklog
   (goto-char (point-min))
   ;; so that search for :END: won't fail
   (org-jira-entry-put (point) "ID" worklog-id)
   (search-forward ":END:" nil 1 1)
   (forward-line)
   (org-trim (buffer-substring-no-properties (point) (point-max)))))

(defun org-jira-id ()
  "Get the ID entry for the current heading."
  (org-entry-get (point) "ID"))

(defun org-jira-filename ()
  "Get the ID entry for the current heading."
  (org-jira-get-from-org 'issue 'filename))

;;;###autoload
(defun org-jira-browse-issue ()
  "Open the current issue in external browser."
  (interactive)
  (org-jira-ensure-on-issue
    (browse-url (concat (replace-regexp-in-string "/*$" "" jiralib-url) "/browse/" (org-jira-id)))))

(defun org-jira-url-copy-file (url newname)
  "Copy a file from a URL to a new location.

Argument NEWNAME is the name of the file to be saved."
  (let ((newname newname))
    (url-retrieve
     url
     (lambda (_status)
       (let ((buffer (current-buffer))
             (handle nil)
             (filename (if (and (file-exists-p newname)
                                org-jira-download-ask-override)
                           (read-string
                            "File already exists, select new name or press ENTER to override: "
                            newname)
                         newname)))
         (if (not buffer)
             (error
              "Opening input file: No such file or directory, %s" url))
         (with-current-buffer buffer
           (setq handle (mm-dissect-buffer t)))
         (mm-save-part-to-file handle filename)
         (kill-buffer buffer)
         (mm-destroy-parts handle))))))

;;;###autoload
(defun org-jira-download-attachment ()
  "Download the attachment under cursor."
  (interactive)
  (when jiralib-use-restapi
    (save-excursion
      (org-up-heading-safe)
      (org-back-to-heading)
      (forward-thing 'whitespace)
      (unless (looking-at "Attachments:")
        (error "Not on a attachment region!")))
    (let ((filename (org-entry-get (point) "Name"))
          (url (org-entry-get (point) "Content"))
          (url-request-extra-headers `(,jiralib-token)))
      (org-jira-url-copy-file
       url
       (concat (file-name-as-directory org-jira-download-dir) filename)))))

;;;###autoload
(defun org-jira-get-issues-from-filter (filter)
  "Get issues from the server-side stored filter named FILTER.

Provide this command in case some users are not able to use
client side jql (maybe because of JIRA server version?)."
  (interactive
   (list (completing-read "Filter: " (mapcar #'cdr (jiralib-get-saved-filters)))))
  (org-jira-get-issues (jiralib-get-issues-from-filter (car (rassoc filter (jiralib-get-saved-filters))))))

;;;###autoload
(defun org-jira-get-issues-from-filter-headonly (filter)
  "Get issues *head only* from saved filter named FILTER.
See `org-jira-get-issues-from-filter'."
  (interactive
   (list (completing-read "Filter: " (mapcar #'cdr (jiralib-get-saved-filters)))))
  (org-jira-get-issues-headonly (jiralib-get-issues-from-filter (car (rassoc filter (jiralib-get-saved-filters))))))



(defun org-jira-open (path)
  "Open a Jira Link from PATH."
  (org-jira-get-issue path))

;;;###autoload
(defun org-jira-get-issues-by-board ()
  "Get list of ISSUES from agile board."
  (interactive)
  (let* ((board (org-jira-read-board))
         (board-id (cdr board)))
    (jiralib-get-board-issues board-id
                              :callback org-jira-get-issue-list-callback
                              :limit (org-jira-get-board-limit board-id)
                              :query-params (org-jira--make-jql-queryparams board-id))))

;;;###autoload
(defun org-jira-get-issues-by-sprint ()
  "Get list of ISSUES from sprint."
  (interactive)
  (let* ((board (org-jira-read-board))
   (board-id (cdr board))
   (sprint (org-jira-read-sprint board-id))
   (sprint-id (cdr sprint)))
    (jiralib-get-sprint-issues sprint-id
             :callback org-jira-get-issue-list-callback
             :limit (org-jira-get-board-limit board-id)
             :query-params (org-jira--make-jql-queryparams board-id))))

(defun org-jira-get-board-limit (id)
  "Get the limit of a JIRA board.

Argument ID is the identifier used to retrieve a board from the buffer."
  (let ((board (org-jira--get-board-from-buffer id)))
    (if (and board (slot-boundp board 'limit))
        (oref board limit)
      org-jira-boards-default-limit)))

(defun org-jira--make-jql-queryparams (board-id)
  "Create JQL query parameters from a given board ID.

Argument BOARD-ID is the identifier of the board from which the JQL query
parameters will be generated."
  (let* ((board (org-jira--get-board-from-buffer board-id))
         (jql (if (and board (slot-boundp board 'jql))
                  (oref board jql))))
    (if (and jql (not (string-blank-p jql))) `((jql ,jql)))))

;;;###autoload
(defun org-jira-get-issues-by-board-headonly ()
  "Get list of ISSUES from agile board, head only."
  (interactive)
  (let* ((board (org-jira-read-board))
         (board-id (cdr board)))
    (org-jira-get-issues-headonly
     (jiralib-get-board-issues board-id
                               :limit (org-jira-get-board-limit board-id)
                               :query-params (org-jira--make-jql-queryparams board-id)))))


(defun org-jira--render-boards-from-list (boards)
  "Add the BOARDS from list into the org file.

Boards is a list of the variable `org-jira-sdk-board' records."
  (mapc #'org-jira--render-board  boards))


(defun org-jira--render-board (board)
  "Render a Jira BOARD in an `org-mode' buffer.

Argument BOARD is a variable that represents a board object with properties such
as id, name, url, board-type, jql, and limit."
  
;;(org-jira-sdk-dump board)
  (with-slots (id name url board-type jql limit) board
    (with-current-buffer (org-jira--get-boards-buffer)
      (org-jira-maybe-activate-mode)
      (org-jira-freeze-ui
        (org-save-outline-visibility t
          (save-restriction
            (outline-show-all)
            (widen)
            (goto-char (point-min))
            (let* ((board-headline
                    (format "Board: [[%s][%s]]" url name))
                   (headline-pos
                    (org-find-exact-headline-in-buffer board-headline
                                                       (current-buffer) t))
                   (entry-exists (and headline-pos (>= headline-pos (point-min))
                                      (<= headline-pos (point-max))))
                   (limit-value  (if (slot-boundp board 'limit)
                                     (int-to-string  limit) nil))
                   (jql-value    (if (slot-boundp board 'jql) jql nil)))
              (if entry-exists
                  (progn
                    (goto-char headline-pos)
                    (org-narrow-to-subtree)
                    (end-of-line))
                (goto-char (point-max))
                (unless (looking-at "^")
                  (insert "\n"))
                (insert "* ")
                (org-jira-insert board-headline)
                (org-narrow-to-subtree))
              (org-jira-entry-put (point) "name" name)
              (org-jira-entry-put (point) "type" board-type)
              (org-jira-entry-put (point) "url"  url)
              ;; do not overwrite existing user properties with empty values
              (if (or (not entry-exists) limit-value)
                  (org-jira-entry-put (point) "limit" limit-value))
              (if (or (not entry-exists) jql-value)
                  (org-jira-entry-put (point) "JQL" jql-value))
              (org-jira-entry-put (point) "ID"   id))))))))

(defun org-jira--get-boards-file ()
  "Get the boards file."
  (expand-file-name "boards-list.org" (org-jira--ensure-working-dir)))

(defun org-jira--get-boards-buffer ()
  "Return buffer for list of agile boards. Create one if it does not exist."
  (let* ((boards-file  (org-jira--get-boards-file))
         (existing-buffer (find-buffer-visiting boards-file)))
    (if existing-buffer
        existing-buffer
      (find-file-noselect boards-file))))

;;;###autoload
(defun org-jira-get-boards ()
  "Get list of boards and their properies."
  (interactive)
  (let* ((datalist (jiralib-get-boards))
         (boards (org-jira-sdk-create-boards-from-data-list datalist)))
    (org-jira--render-boards-from-list boards))
  (switch-to-buffer (org-jira--get-boards-buffer)))

(defun org-jira--get-board-from-buffer (id)
  "Get board from buffer using ID.

Argument ID is the identifier used to find the position of a board in the
buffer."
  (with-current-buffer (org-jira--get-boards-buffer)
    (org-jira-freeze-ui
      (let ((pos (org-find-property "ID" (int-to-string  id))))
        (if pos
            (progn
              (goto-char pos)
              (apply #'org-jira-sdk-board
                     (cl-reduce
                      #'(lambda (acc entry)
                          (let* ((pname   (car entry))
                                 (pval (cdr entry))
                                 (pair (and pval
                                            (not (string-empty-p pval))
                                            (cond ((equal pname "ID")
                                                   (list :id pval))
                                                  ((equal pname "URL")
                                                   (list :url pval))
                                                  ((equal pname "TYPE")
                                                   (list :board-type pval))
                                                  ((equal pname "NAME")
                                                   (list :name pval))
                                                  ((equal pname "LIMIT")
                                                   (list :limit (string-to-number
                                                                 pval)))
                                                  ((equal pname "JQL")
                                                   (list :jql pval))
                                                  (t nil)))))
                            (if pair  (append pair acc)  acc)))
                      (org-entry-properties) :initial-value  ()))))))))

(defun org-jira-get-org-keyword-from-status (status)
  "Gets an `org-mode' keyword corresponding to a given jira STATUS."
  (if org-jira-use-status-as-todo
      (upcase (replace-regexp-in-string " " "-" status))
    (let ((known-keyword (assoc status org-jira-jira-status-to-org-keyword-alist)))
      (cond (known-keyword (cdr known-keyword))
            ((member (org-jira-decode status) org-jira-done-states) "DONE")
            ("TODO")))))

(defun org-jira-get-org-priority-string (character)
  "Return an org-priority-string based on CHARACTER and user settings."
  (cond ((not character) "")
        ((and org-jira-priority-to-org-priority-omit-default-priority
              (eq character org-default-priority))
         "")
        (t (format "[#%c] " character))))

(defun org-jira-get-org-priority-cookie-from-issue (priority)
  "Get the `org-mode' [#X] PRIORITY cookie."
  (let ((character (cdr (assoc priority org-jira-priority-to-org-priority-alist))))
    (org-jira-get-org-priority-string character)))

  (defun org-jira-mini-read-auth (url &optional user)
  "Return cons with USER and host URL and token if found in `auth-sources.'"
  (require 'auth-source)
  (when-let* ((host
               (when url
                 (replace-regexp-in-string "^http[s]?://" "" url)))
              (variants
               (seq-uniq
                (if user
                    (when (fboundp 'auth-source-search)
                      (auth-source-search
                       :user user
                       :host host
                       :max most-positive-fixnum))
                  (auth-source-search
                   :host host
                   :max most-positive-fixnum))
                (lambda (a b)
                  (when (fboundp 'auth-info-password)
                    (equal (auth-info-password a)
                           (auth-info-password b))))))
              (found (if (= (length variants) 1)
                         (car variants)
                       (car (auth-source-search
                             :host host
                             :user (completing-read
                                    "User:\s"
                                    (mapcar
                                     (lambda (it)
                                       (plist-get it :user))
                                     variants)
                                    nil t))))))
    (let ((token (auth-info-password found))
          (user (plist-get found :user)))
      (cons user token))))

;;;###autoload
(defun org-jira-mini-login ()
  "Login to jira."
  (interactive)
  (let ((auth (org-jira-mini-read-auth jiralib-url)))
    (setq jiralib-token (cons "Authorization"
                              (concat "Bearer "
                                      (cdr auth))))
    (jiralib-login (car auth)
                   (cdr auth))))


(defvar org-jira-mini-current-tasks nil)
(defvar org-jira-mini-issues nil)
(defvar org-jira-mini-loading nil)

(defun org-jira-mini-hours-to-seconds (hours)
  "Convert integer HOURS to seconds."
  (* hours 3600))

(defun org-jira-mini-time-format-to-iso-date-time (&optional time zone)
  "Format TIME with ZONE to iso date string."
  (format-time-string "%Y-%m-%dT%T.%3N%z" time zone))

(defun org-jira-mini-alist-get (key alist)
  "Find the first element of ALIST whose car equals KEY and return its cdr."
  (cdr (assoc key alist)))

(defun org-jira-mini-plist-props (keywords plist)
  "Take values of KEYWORDS props from PLIST."
  (mapcar (apply-partially #'plist-get plist) keywords))

(defun org-jira-mini-s-strip-props (item)
  "If ITEM is string, return it without text properties.

 If ITEM is symbol, return it is `symbol-name.'
 Otherwise return nil."
  (cond ((stringp item)
         (let ((str (seq-copy item)))
           (set-text-properties 0 (length str) nil str)
           str))
        ((and item (symbolp item))
         (symbol-name item))
        (nil item)))

(defun org-jira-mini-get-issue-key (issue)
  "Split ISSUE string and return first element without text props."
  (org-jira-mini-s-strip-props (car (split-string issue nil t))))

(defun org-jira-mini-issue-display-to-real (issue)
  "Return cons which car is ISSUE key and cdr is org element."
  (assoc (org-jira-mini-get-issue-key (org-jira-mini-s-strip-props issue))
         org-jira-mini-current-tasks))

(defun org-jira-mini-issue-display-to-real-action (action)
  "Return function that call ACTION with issue cons.
The car is ISSUE key and cdr is org element."
  (lambda (c)
    (funcall action (org-jira-mini-issue-display-to-real c))))

(defun org-jira-mini-issue-display-to-issue-key-action (action)
  "Return a lambda function that call an ACTION with one argument."
  (lambda (c)
    (funcall action (org-jira-mini-get-issue-key c))))

(defun org-jira-mini-browse-issue (issue-key)
  "Open the JIRA issue with the provided ISSUE-KEY in a web browser."
  (browse-url (concat jiralib-host "/browse/" issue-key)))

(defun org-jira-mini-copy-branch-action (issue)
  "Copy the branch name from the given ISSUE and return it as a string.
Argument ISSUE is the issue from which to create the branch name.
Return the branch name as a string.
If the branch name is successfully created, copy it to the kill ring and display
a message.
If the branch name cannot be created, raise an error with a message."
  (if-let ((pl (caddr issue)))
      (let* ((issuetype (downcase (or (plist-get pl :type) "")))
             (type (or (car (member issuetype '("bug" "feature")))
                       "feature"))
             (key (plist-get pl :CUSTOM_ID))
             (branch (format "%s/%s" type key)))
        (kill-new branch)
        (message "copied %s" branch)
        branch)
    (error (format "Could not make branch from %s" issue))))

(defun org-jira-mini-get-project-filenames ()
  "Return filenames with fetched projects."
  (let ((projects-keys (mapcar
                        (apply-partially #'org-jira-mini-alist-get 'key)
                        (jiralib-get-projects)))
        (files (delete ".." (delete "." (directory-files
                                         org-jira-working-dir)))))
    (mapcar (org-jira-mini-fp-rpartial expand-file-name org-jira-working-dir)
            (seq-intersection files (mapcar (org-jira-mini-fp-rpartial concat ".org")
                                            projects-keys)))))

(defun org-jira-mini-get-projects-buffers ()
  "Return projects buffers."
  (delq nil (mapcar (org-jira-mini-fp-compose
                     #'get-file-buffer
                     (org-jira-mini-fp-rpartial expand-file-name org-jira-working-dir))
                    (directory-files org-jira-working-dir nil
                                     directory-files-no-dot-files-regexp
                                     t))))

(defun org-jira-mini-save-all-project-buffers ()
  "Save all jira buffers."
  (dolist (buff (org-jira-mini-get-projects-buffers))
    (org-jira-mini-save-buffer buff)))

(defun org-jira-mini-jump-to-jira-issue (issue)
  "Jump to jira ISSUE."
  (when-let* ((issue (or (assoc issue org-jira-mini-current-tasks) issue))
              (pl (caddr issue))
              (buff (with-current-buffer
                        (or (get-file-buffer (plist-get pl
                                                        :file))
                            (find-file-noselect
                             (plist-get pl
                                        :file)))
                      (widen)
                      (goto-char (plist-get pl :begin))
                      (narrow-to-region (plist-get pl :begin)
                                        (plist-get pl :end))
                      (org-fold-show-all)
                      (current-buffer))))
    (if (minibuffer-window-active-p (selected-window))
        (with-minibuffer-selected-window
          (pop-to-buffer-same-window buff))
      (pop-to-buffer-same-window buff))))

(defun org-jira-mini-init-issues ()
  "Initialize JIRA issues by retrieving tasks from project files.
This function does not accept any arguments.
This function sets the variable `org-jira-mini-current-tasks` to a list
of JIRA tasks extracted from project files.
This function initializes JIRA issues by retrieving tasks from project files and
storing them in the variable `org-jira-mini-current-tasks`."
  (setq org-jira-mini-current-tasks
        (seq-reduce (lambda (acc file)
                      (let ((items (with-current-buffer
                                       (find-file-noselect
                                        file)
                                     (org-with-wide-buffer
                                      (let ((ids))
                                        (org-map-entries
                                         (lambda
                                           ()
                                           (let* ((elem
                                                   (org-element-at-point))
                                                  (props
                                                   (cadr
                                                    elem)))
                                             (when (plist-get
                                                    props
                                                    :CUSTOM_ID)
                                               (plist-put
                                                props
                                                :file
                                                file)
                                               (push
                                                (cons
                                                 (plist-get
                                                  props
                                                  :CUSTOM_ID)
                                                 elem)
                                                ids)))))
                                        ids)))))
                        (setq acc (nconc items acc))))
                    (org-jira-mini-get-project-filenames) '())))

(defun org-jira-mini-fontify-issue (issue-str)
  "Fontify a string ISSUE-STR.
ISSUE-STR is a JIRA issue string to fontify."
  (let* ((parts (split-string issue-str nil t))
         (id (pop parts))
         (status (org-jira-mini-s-strip-props (car (reverse parts))))
         (title (string-join (butlast parts) "\s")))
    (if-let ((face (org-get-todo-face status)))
        (concat (propertize id 'face face) "\s" title "\s"
                (propertize status 'face face))
      issue-str)))

(defun org-jira-mini-transfrom-org-isssue (issue)
  "Convert org element with ISSUE to string."
  (if-let ((pl (caddr issue)))
      (org-jira-mini-fontify-issue
       (string-join (delete nil
                            (org-jira-mini-plist-props
                             '(:CUSTOM_ID :raw-value
                                          :todo-keyword)
                             pl))
                    "\s"))
    issue))

(defun org-jira-mini-jump-to-issue-other-window (issue)
  "Jump to jira ISSUE in other window."
  (let* ((orig-wind (selected-window))
         (wind-target (if (minibuffer-window-active-p orig-wind)
                          (with-minibuffer-selected-window
                            (let ((wind (selected-window)))
                              (or
                               (window-right wind)
                               (window-left wind)
                               (split-window-right))))
                        (let ((wind (selected-window)))
                          (or
                           (window-right wind)
                           (window-left wind)
                           (split-window-right))))))
    (with-selected-window wind-target
      (org-jira-mini-jump-to-jira-issue issue))))

(defun org-jira-mini-read-woklog-data ()
  "Read start date and duration for worklog.
Result is a list with start date in iso format and duration in seconds."
  (require 'idate nil t)
  (let* ((start-date (org-jira-mini-time-format-to-iso-date-time
                      (when (fboundp 'idate-read)
                        (idate-read
                       "Worklog start time  "))
                      "UTC"))
         (hours (read-number "Hours:" 8))
         (secs (org-jira-mini-hours-to-seconds hours)))
    (list start-date secs)))

(defun org-jira-mini-add-or-update-worklog (issue-key &optional worklog-id)
  "Add or update (if WORKLOG-ID is non nil) worklog for ISSUE-KEY."
  (when (listp issue-key)
    (setq issue-key (car issue-key)))
  (let* ((args (append (delete nil (list issue-key worklog-id))
                       (org-jira-mini-read-woklog-data)
                       (list nil)
                       (list nil))))
    (if worklog-id
        (apply #'jiralib-update-worklog args)
      (apply #'jiralib-add-worklog args))))

(defun org-jira-mini-update-worklog (issue-key)
  "Update worklog in ISSUE-KEY."
  (when (listp issue-key)
    (setq issue-key (car issue-key)))
  (let* ((logs
          (append
           (cdr (assoc 'worklogs (jiralib-get-worklogs issue-key nil))) nil))
         (wauthors (mapcar
                    (lambda (it)
                      (cdr (assoc 'emailAddress (cdr (assoc 'author it)))))
                    logs))
         (author (or
                  (when (bound-and-true-p jiralib-user-login-name)
                    (member jiralib-user-login-name wauthors))
                  (completing-read "Auhtor: " wauthors)))
         (filtered-logs (seq-filter
                         (lambda (it)
                           (equal
                            (cdr
                             (assoc 'emailAddress
                                    (cdr (assoc
                                          'author
                                          it))))
                            author))
                         logs))
         (worklog-id
          (car (last (split-string (completing-read ""
                                                    (mapcar
                                                     (lambda (it)
                                                       (let ((updated
                                                              (cdr
                                                               (assoc
                                                                'updated
                                                                it)))
                                                             (id
                                                              (cdr
                                                               (assoc
                                                                'id
                                                                it)))
                                                             (timeSpent
                                                              (cdr
                                                               (assoc
                                                                'timeSpent
                                                                it))))
                                                         (string-join
                                                          (list
                                                           timeSpent
                                                           updated
                                                           id)
                                                          " ")))
                                                     filtered-logs))
                                   nil t)))))
    (org-jira-mini-add-or-update-worklog issue-key worklog-id)))

(defun org-jira-mini-save-buffer (buffer)
  "Silently save BUFFER if modified."
  (when (and
         (buffer-live-p buffer)
         (buffer-modified-p buffer))
    (with-current-buffer buffer
      (let ((inhibit-message t))
        (save-buffer)))))

(defvar org-jira-mini-timer nil)

(defun org-jira-mini-wait (buffer)
  "Wait for a BUFFER to stop being modified and save it periodically.
Argument BUFFER is the buffer to wait for."
  (let ((count 0))
    (while (and
            (buffer-live-p buffer)
            (buffer-modified-p buffer))
      (setq count (1+ count))
      (org-jira-mini-save-buffer buffer)
      (sit-for 0.1))
    (org-jira-mini-save-buffer buffer)))

(defun org-jira-mini-render-issues-from-issue-list (Issues)
  "Add the issues from ISSUES list into the org file(s).

ISSUES is a list of the variable `org-jira-sdk-issue' records."
;; FIXME: Some type of loading error - the first async callback does not know about
;; the issues existing as a class, so we may need to instantiate here if we have none.
  (when (eq 0 (length
               (seq-filter #'org-jira-sdk-isa-issue? Issues)))
    (setq Issues (org-jira-sdk-create-issues-from-data-list Issues)))
    ;; First off, we never ever want to run on non-issues, so check our types early.
  (setq Issues (seq-filter #'org-jira-sdk-isa-issue? Issues))
  (org-jira-log (format "About to render %d issues." (length Issues)))
  ;; If we have any left, we map over them.
  (mapc #'org-jira--render-issue Issues)
  (org-jira--get-project-buffer (-last-item Issues)))

(defun org-jira-mini-async-callback (&rest args)
  "Callback for async, ARGS is the response from the request call.
Will send a list of `'org-jira-sdk-issue' objects to the list printer."
  (let* ((data
          (car
           (cdr
            (plist-member args ':data)))))
    (let ((it data))
      (let ((it
             (org-jira-sdk-path it
                                '(issues))))
        (let ((it
               (append it nil)))
          (let ((it
                 (org-jira-sdk-create-issues-from-data-list
                  it)))
            (let ((buff
                   (org-jira-mini-render-issues-from-issue-list
                    it)))
              (org-jira-mini-wait buff)
              (run-with-timer 0.5 nil
                              (lambda
                                ()
                                (org-jira-mini-save-all-project-buffers)
                                (org-jira-mini-map-issues)
                                (setq org-jira-mini-loading nil))))))))))

(defun org-jira-mini-map-issues ()
  "Set `org-jira-mini-issues'."
  (setq org-jira-mini-issues (mapcar #'org-jira-mini-transfrom-org-isssue
                               (org-jira-mini-init-issues))))

(defun org-jira-mini-async-request ()
  "Call `org-jira-get-issue-list' with callback `org-jira-mini-async-callback'."
  (setq org-jira-mini-loading t)
  (let ((inhibit-message t))
    (org-jira-get-issue-list
     #'org-jira-mini-async-callback)))

(defun org-jira-mini-defun-ivy-bind-actions (actions keymap &optional command-name)
  "Bind ivy ACTIONS to KEYMAP.
Optional argument COMMAND-NAME is used for actions documentation."
  (let ((map keymap)
        (result)
        (i))
    (dolist (a actions)
      (setq i (if i (1+ i) 0))
      (let ((name)
            (name-parts (list command-name)))
        (let ((key-str (pop a))
              (func (seq-find #'functionp a)))
          (let ((func-name
                 (when (symbolp func)
                   (symbol-name func)))
                (arity (help-function-arglist func))
                (keybind (kbd key-str))
                (action-key
                 (car (last (split-string
                             key-str "" t))))
                (descr
                 (format "%s [%s]"
                         (or (seq-find
                              #'stringp a)
                             (seq-find
                              (lambda (it)
                                (and
                                 (not (string-prefix-p "ivy-" it))
                                 (functionp (intern it))))
                              (split-string
                               (format "%s" func)
                               "[\s\f\t\n\r\v)(']+" t))
                             "")
                         key-str))
                (no-exit (not (null (memq :no-exit a))))
                (doc-func)
                (doc))
            (when func-name
              (push func-name name-parts))
            (setq name-parts (reverse (delete nil name-parts)))
            (setq name (format "%s-action-%s" (string-join name-parts "-") i))
            (setq doc-func (or (format "`%s'" func-name)
                               "action"))
            (setq doc (cond ((and (null arity)
                                  no-exit)
                             (concat "Call "
                                     doc-func
                                     " without args.\n"
                                     "Doesn't quit minibuffer."))
                            ((and (null arity)
                                  (null no-exit))
                             (concat "Quit the minibuffer and calls "
                                     doc-func
                                     " without args."))
                            ((and no-exit arity)
                             (concat "Call " doc-func
                                     " with current candidate.\n"
                                     "Doesn't quit minibuffer."))
                            (t (concat "Quit the minibuffer and call "
                                       doc-func
                                       " afterwards."))))
            (define-key map keybind
                        (cond ((and (null arity)
                                    no-exit)
                               (defalias (make-symbol name)
                                 (lambda ()
                                   (interactive)
                                   (funcall func))
                                 doc))
                              ((and (null arity)
                                    (null no-exit))
                               (defalias (make-symbol name)
                                 (lambda ()
                                   (interactive)
                                   (put 'quit 'error-message "")
                                   (run-at-time nil nil
                                                (lambda ()
                                                  (put 'quit 'error-message
                                                       "Quit")
                                                  (with-demoted-errors
                                                      "Error: %S"
                                                    (funcall func))))
                                   (abort-recursive-edit))
                                 doc))
                              ((and no-exit arity)
                               (defalias (make-symbol name)
                                 (lambda ()
                                   (interactive)
                                   (let ((current
                                          (or
                                           (when (and (fboundp
                                                       'ivy-state-current)
                                                      (boundp 'ivy-last))
                                             (ivy-state-current
                                              ivy-last))
                                           (when (boundp 'ivy-text)
                                             ivy-text)))
                                         (window
                                          (when (and (fboundp
                                                      'ivy--get-window)
                                                     (boundp 'ivy-last))
                                            (ivy--get-window ivy-last))))
                                     (with-selected-window
                                         window
                                       (funcall func current))))
                                 doc))
                              (t (defalias (make-symbol name)
                                   (lambda ()
                                     (interactive)
                                     (when (fboundp 'ivy-exit-with-action)
                                       (ivy-exit-with-action func)))
                                   doc))))
            (push (list action-key func descr) result)))))
    result))

(defvar org-jira-mini-ivy-keymap
  (let ((map (make-sparse-keymap)))
    map))

(defun org-jira-mini-read-setup-minibuffer ()
  "Setup minuffer."
  (pcase completing-read-function
    ('ivy-completing-read
     (let ((actions (org-jira-mini-defun-ivy-bind-actions
                     `(("C-j"
                        ,(org-jira-mini-issue-display-to-real-action
                          'org-jira-mini-jump-to-jira-issue)
                        "jump" :no-exit t)
                       ("C-c g g"
                        ,(org-jira-mini-issue-display-to-issue-key-action
                          'org-jira-mini-browse-issue)
                        "open with browser")
                       ("<C-return>"
                        ,(org-jira-mini-issue-display-to-issue-key-action
                          'org-jira-mini-browse-issue)
                        "open with browser")
                       ("C-c o"
                        ,(org-jira-mini-issue-display-to-real-action
                          'org-jira-mini-jump-to-issue-other-window)
                        "jump to other window")
                       ("C-c w"
                        ,(org-jira-mini-issue-display-to-real-action
                          'org-jira-mini-add-or-update-worklog)
                        "add worklog")
                       ("C-c u"
                        ,(org-jira-mini-issue-display-to-real-action
                          'org-jira-mini-update-worklog)
                        "update worklog")
                       ("M-g"
                        ,(org-jira-mini-issue-display-to-real-action
                          'org-jira-mini-copy-branch-action)
                        "copy git branch"))
                     org-jira-mini-ivy-keymap)))
       (when (fboundp 'ivy-set-actions)
         (ivy-set-actions 'org-jira-mini-read-issues-sync
                          actions))
       (use-local-map
        (let ((map (copy-keymap
                    org-jira-mini-ivy-keymap)))
          (set-keymap-parent map (current-local-map))
          map))))))

(defvar-local org-jira-mini-executing-macro nil)

(defun org-jira-mini-run-in-minibuffer ()
  "Run a macro in the minibuffer using the first four characters of an issue.
This function does not take any arguments.
This function runs a macro in the minibuffer window using the first four
characters of a JIRA issue as input.
When called, this function will run a macro in the minibuffer window using the
first four characters of a JIRA issue as input."
  (when-let ((mini (active-minibuffer-window))
             (word (car org-jira-mini-issues)))
    (with-selected-window (active-minibuffer-window)
      (setq org-jira-mini-executing-macro t)
      (let ((parts (seq-take (split-string word "" t) 4)))
        (while-no-input
          (dolist (c parts)
            (execute-kbd-macro c)))))))

(declare-function ivy-update-candidates "ivy")
(defun org-jira-mini-read-issues (&optional action)
  "Read JIRA issues and display them in the minibuffer for selection.
Optional argument ACTION is a function to be called with the selected issue.
Reads JIRA issues and displays them in the minibuffer for selection.
Returns the selected issue."
  (let ((done nil)
        (result)
        (org-jira-mini-timer)
        (request)
        (rendered-lengths 0))
    (setq org-jira-mini-timer
          (run-with-timer 0.3
                          0.3
                          (lambda ()
                            (unless request (setq request
                                                  (org-jira-mini-async-request)))
                            (unless done
                              (when-let ((mini
                                          (and
                                           org-jira-mini-issues
                                           (not done)
                                           (active-minibuffer-window))))
                                (when (> (length org-jira-mini-issues)
                                         rendered-lengths)
                                  (setq rendered-lengths
                                        (length org-jira-mini-issues))
                                  (with-selected-window
                                      mini
                                    (cond ((and (or (bound-and-true-p fido-mode)
                                                    (bound-and-true-p
                                                     fido-vertical-mode))
                                                (fboundp 'icomplete-exhibit))
                                           (icomplete-exhibit))
                                          ((and
                                            (eq completing-read-function
                                                'ivy-completing-read))
                                           (ivy-update-candidates
                                            (org-jira-mini-map-issues))))
                                    (unless (or org-jira-mini-executing-macro
                                                (not (car org-jira-mini-issues)))
                                      (org-jira-mini-run-in-minibuffer)))))))))
    (unwind-protect
        (minibuffer-with-setup-hook #'org-jira-mini-read-setup-minibuffer
          (setq result (completing-read
                        "Issue "
                        (completion-table-dynamic (lambda (&rest _i)
                                                    org-jira-mini-issues)))))
      (when org-jira-mini-timer
        (cancel-timer org-jira-mini-timer)
        (setq org-jira-mini-timer nil)))
    (if action
        (funcall action (org-jira-mini-issue-display-to-real result)))
    result))

;;;###autoload
(defun org-jira-mini-jump-to-issue ()
  "Jump to a JIRA issue."
  (interactive)
  (org-jira-mini-read-issues #'org-jira-mini-jump-to-jira-issue))

;;;###autoload
(defun org-jira-mini-copy-issue-key ()
  "Copy the issue key of a JIRA issue to the kill ring."
  (interactive)
  (org-jira-mini-read-issues (org-jira-mini-fp-compose (org-jira-mini-fp-converge message
                                                      [identity kill-new])
                                         car-safe)))

;;;###autoload
(defun org-jira-mini-update-issue-worklog ()
  "Read issues from JIRA and update the worklog for each issue."
  (interactive)
  (org-jira-mini-read-issues #'org-jira-mini-update-worklog))

;;;###autoload
(defun org-jira-mini-add-issue-worklog ()
  "Read issues from JIRA and add or update worklog for each issue."
  (interactive)
  (org-jira-mini-read-issues #'org-jira-mini-add-or-update-worklog))

;;;###autoload (autoload 'org-jira-menu "org-jira.el" nil t)
(transient-define-prefix org-jira-menu ()
  "Command dispatcher for Jira commands."
  [["Issues"
    ("b" "Jump to issue" org-jira-mini-jump-to-issue)
    ("c" "Copy" org-jira-mini-copy-issue-key)]
   ["Worklog"
    ("wa" "Add" org-jira-mini-add-issue-worklog)
    ("wu" "Update" org-jira-mini-update-issue-worklog)
    ("wU" "Update Worklogs From Org Clocks"
     org-jira-update-worklogs-from-org-clocks)]]
  [:if-derived org-mode
               ("J" "Todo To Jira" org-jira-todo-to-jira :inapt-if
                org-jira-parse-issue-id)
               ("+" "Add Comment" org-jira-add-comment)
               ("-" "Update Comment" org-jira-update-comment)
               ("S" "Create Subtask" org-jira-create-subtask)
               ("t" "Get Subtasks" org-jira-get-subtasks :inapt-if-not
                org-jira-mini-on-issue-p)
               ("R" "Refresh Issues In Buffer"
                org-jira-refresh-issues-in-buffer)
               ("a" "Assign Issue" org-jira-assign-issue)
               ("j" "Browse Issue" org-jira-browse-issue :inapt-if-not
                org-jira-mini-on-issue-p)
               ("C" "Create Issue" org-jira-create-issue)
               ("f" "Get Issues By Fixversion"
                org-jira-get-issues-by-fixversion)
               ("i" "Get Issues" org-jira-get-issues)
               ("h" "Get Issues Headonly" org-jira-get-issues-headonly)
               ("y" "Copy Current Issue Key" org-jira-copy-current-issue-key
                :inapt-if-not org-jira-mini-on-issue-p)
               ("n" "Progress issue" org-jira-progress-issue-next
                :inapt-if-not org-jira-mini-on-issue-p)
               ("g" "Refresh Issue" org-jira-refresh-issue
                :inapt-if-not org-jira-mini-on-issue-p)
               ("U" "Update Issue" org-jira-update-issue :inapt-if-not
                org-jira-id)
               ("p" "Progress Issue" org-jira-progress-issue :inapt-if-not
                org-jira-id)
               ("l" "Get Issues From Custom Jql"
                org-jira-get-issues-from-custom-jql)
               ("I" "Get Issues By Board" org-jira-get-issues-by-board)
               ("B" "Get Boards" org-jira-get-boards)
               ("P" "Get Projects" org-jira-get-projects)]
  (interactive)
  (unless jiralib-token
    (org-jira-mini-login))
  (transient-setup 'org-jira-menu))

(provide 'org-jira)
;;; org-jira.el ends here
