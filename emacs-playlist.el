;;; emacs-playlist.el --- Search YouTube and build playlists for norns -*- lexical-binding: t; -*-

;; Author: noonker
;; URL: https://github.com/noonker/emacs-playlist

;;; Commentary:
;; Search YouTube via yt-dlp, build a playlist in a tabulated list,
;; then download and convert audio to 48 kHz for norns (or other targets).

;;; Code:

(require 'tabulated-list)
(require 'cl-lib)

;;;; Customization

(defgroup emacs-playlist nil
  "Search YouTube and download audio playlists."
  :group 'multimedia
  :prefix "emacs-playlist-")

(defcustom emacs-playlist-search-results 10
  "Number of results to return per search."
  :type 'integer)

(defcustom emacs-playlist-download-dir
  (expand-file-name "emacs-playlist" temporary-file-directory)
  "Temporary directory for downloaded audio."
  :type 'directory)

(defcustom emacs-playlist-sample-rate 48000
  "Target sample rate for ffmpeg conversion."
  :type 'integer)

(defcustom emacs-playlist-max-concurrent 2
  "Maximum number of concurrent yt-dlp downloads."
  :type 'integer)

(defcustom emacs-playlist-norns-host "norns.local"
  "Hostname or IP of the norns device."
  :type 'string)

(defcustom emacs-playlist-norns-user "we"
  "SSH user for the norns device."
  :type 'string)

(defcustom emacs-playlist-vlc-host "192.168.50.140"
  "Host running VLC Wi-Fi sharing."
  :type 'string)

(defcustom emacs-playlist-vlc-port 80
  "Port for VLC Wi-Fi sharing."
  :type 'integer)

(defcustom emacs-playlist-destinations
  '(("Norns"           . emacs-playlist--send-norns)
    ("VLC Wi-Fi Share" . emacs-playlist--send-vlc)
    ("Open Folder"     . emacs-playlist--send-open-folder))
  "Alist of (LABEL . FUNCTION).
Each function is called with a list of downloaded file paths."
  :type '(alist :key-type string :value-type function))

;;;; Internal state

(defvar emacs-playlist--search-results nil
  "Vector of search result entries for the current search buffer.")

(defvar emacs-playlist--playlist nil
  "List of plists representing songs added to the current playlist.")

(defvar emacs-playlist--playlist-buffer-name "*emacs-playlist*"
  "Name of the playlist review buffer.")

(defvar-local emacs-playlist--marked nil
  "Set of tabulated-list IDs that are marked in the current search buffer.")

;;;; Filename sanitization

(defun emacs-playlist--sanitize-filename (title)
  "Convert TITLE to a safe filename: lowercase, no symbols, spaces become dashes."
  (let ((name (downcase title)))
    (setq name (replace-regexp-in-string "[^a-z0-9 -]" "" name))
    (setq name (replace-regexp-in-string "  +" " " name))
    (setq name (replace-regexp-in-string " " "-" name))
    (setq name (replace-regexp-in-string "--+" "-" name))
    (setq name (replace-regexp-in-string "^-\\|-$" "" name))
    name))

;;;; Duration formatting

(defun emacs-playlist--format-duration (seconds)
  "Format SECONDS as M:SS or H:MM:SS."
  (if (or (null seconds) (not (numberp seconds)))
      "?"
    (let ((s (truncate seconds)))
      (if (>= s 3600)
          (format "%d:%02d:%02d" (/ s 3600) (/ (% s 3600) 60) (% s 60))
        (format "%d:%02d" (/ s 60) (% s 60))))))

;;;; View count formatting

(defun emacs-playlist--format-views (count)
  "Format COUNT as a short human-readable string."
  (cond
   ((or (null count) (not (numberp count))) "?")
   ((>= count 1000000000) (format "%.1fB" (/ count 1000000000.0)))
   ((>= count 1000000) (format "%.1fM" (/ count 1000000.0)))
   ((>= count 1000) (format "%.1fK" (/ count 1000.0)))
   (t (number-to-string count))))

;;;; Search

(defun emacs-playlist--parse-search-json (output)
  "Parse yt-dlp JSON OUTPUT lines into a list of plists."
  (let ((results nil))
    (dolist (line (split-string output "\n" t))
      (condition-case nil
          (let* ((json (json-parse-string line :object-type 'alist))
                 (entry (list :id (alist-get 'id json)
                              :title (or (alist-get 'title json) "Unknown")
                              :channel (or (alist-get 'channel json)
                                           (alist-get 'uploader json) "?")
                              :duration (alist-get 'duration json)
                              :views (alist-get 'view_count json)
                              :url (alist-get 'webpage_url json))))
            (push entry results))
        (error nil)))
    (nreverse results)))

(defun emacs-playlist-search (query)
  "Search YouTube for QUERY and display results."
  (interactive "sSearch YouTube: ")
  (let* ((buf (get-buffer-create (format "*yt-search: %s*" query)))
         (search-term (format "ytsearch%d:%s"
                              emacs-playlist-search-results query)))
    (message "Searching YouTube for \"%s\"..." query)
    (set-process-sentinel
     (start-process "emacs-playlist-search" buf
                    "yt-dlp" search-term "--flat-playlist" "-j")
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (if (not (zerop (process-exit-status proc)))
             (message "Search failed (exit %d)" (process-exit-status proc))
           (let ((results (with-current-buffer (process-buffer proc)
                            (emacs-playlist--parse-search-json
                             (buffer-string)))))
             (kill-buffer (process-buffer proc))
             (if (null results)
                 (message "No results found for \"%s\"" query)
               (emacs-playlist--show-search-results results query)))))))))

(defun emacs-playlist--show-search-results (results query)
  "Display RESULTS in a tabulated list buffer for QUERY."
  (let ((buf (get-buffer-create (format "*yt-search: %s*" query))))
    (with-current-buffer buf
      (emacs-playlist-search-mode)
      (setq-local emacs-playlist--search-results results)
      (setq emacs-playlist--marked (make-hash-table :test #'eql))
      (setq tabulated-list-entries
            (cl-loop for entry in results
                     for i from 0
                     collect
                     (list i (vector
                              " "
                              (emacs-playlist--format-duration
                               (plist-get entry :duration))
                              (plist-get entry :title)
                              (plist-get entry :channel)
                              (emacs-playlist--format-views
                               (plist-get entry :views))))))
      (tabulated-list-print t))
    (pop-to-buffer buf)
    (message "%d results for \"%s\" — m to mark, a to add at point, P to view playlist"
             (length results) query)))

;;;; Search results mode

(defvar emacs-playlist-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'emacs-playlist-search-mark)
    (define-key map (kbd "u") #'emacs-playlist-search-unmark)
    (define-key map (kbd "U") #'emacs-playlist-search-unmark-all)
    (define-key map (kbd "a") #'emacs-playlist-search-add-at-point)
    (define-key map (kbd "x") #'emacs-playlist-search-add-marked)
    (define-key map (kbd "P") #'emacs-playlist-show-playlist)
    (define-key map (kbd "s") #'emacs-playlist-search)
    (define-key map (kbd "d") #'emacs-playlist-finalize)
    map)
  "Keymap for `emacs-playlist-search-mode'.")

(define-derived-mode emacs-playlist-search-mode tabulated-list-mode
  "YT-Search"
  "Major mode for browsing YouTube search results.

\\{emacs-playlist-search-mode-map}"
  (setq tabulated-list-format
        [("M" 1 t)
         ("Duration" 9 t)
         ("Title" 55 t)
         ("Channel" 25 t)
         ("Views" 8 t :right-align t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun emacs-playlist-search-mark ()
  "Mark the entry at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (puthash id t emacs-playlist--marked)
      (tabulated-list-set-col 0 "*")
      (forward-line 1))))

(defun emacs-playlist-search-unmark ()
  "Unmark the entry at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (remhash id emacs-playlist--marked)
      (tabulated-list-set-col 0 " ")
      (forward-line 1))))

(defun emacs-playlist-search-unmark-all ()
  "Unmark all entries."
  (interactive)
  (clrhash emacs-playlist--marked)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (tabulated-list-get-entry)
        (tabulated-list-set-col 0 " "))
      (forward-line 1))))

(defun emacs-playlist--get-entry-at-point ()
  "Return the search result plist for the entry at point."
  (let ((id (tabulated-list-get-id)))
    (when (and id emacs-playlist--search-results)
      (nth id emacs-playlist--search-results))))

(defun emacs-playlist-search-add-at-point ()
  "Add the entry at point to the playlist."
  (interactive)
  (let ((entry (emacs-playlist--get-entry-at-point)))
    (if (not entry)
        (user-error "No entry at point")
      (if (cl-find (plist-get entry :url) emacs-playlist--playlist
                   :key (lambda (e) (plist-get e :url))
                   :test #'string=)
          (message "Already in playlist: %s" (plist-get entry :title))
        (push entry emacs-playlist--playlist)
        (tabulated-list-set-col 0 "+")
        (message "Added to playlist: %s (%d total)"
                 (plist-get entry :title)
                 (length emacs-playlist--playlist))))))

(defun emacs-playlist-search-add-marked ()
  "Add all marked entries to the playlist."
  (interactive)
  (let ((added 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          (when (and id (gethash id emacs-playlist--marked))
            (let ((entry (nth id emacs-playlist--search-results)))
              (when (and entry
                         (not (cl-find (plist-get entry :url)
                                       emacs-playlist--playlist
                                       :key (lambda (e) (plist-get e :url))
                                       :test #'string=)))
                (push entry emacs-playlist--playlist)
                (tabulated-list-set-col 0 "+")
                (remhash id emacs-playlist--marked)
                (cl-incf added)))))
        (forward-line 1)))
    (message "Added %d to playlist (%d total)" added
             (length emacs-playlist--playlist))))

;;;; Playlist review mode

(defvar emacs-playlist-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "d") #'emacs-playlist-remove-at-point)
    (define-key map (kbd "D") #'emacs-playlist-clear)
    (define-key map (kbd "s") #'emacs-playlist-search)
    (define-key map (kbd "f") #'emacs-playlist-finalize)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `emacs-playlist-mode'.")

(define-derived-mode emacs-playlist-mode tabulated-list-mode
  "Playlist"
  "Major mode for reviewing the current playlist.

\\{emacs-playlist-mode-map}"
  (setq tabulated-list-format
        [("#" 3 t)
         ("Duration" 9 t)
         ("Title" 55 t)
         ("Channel" 25 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun emacs-playlist-show-playlist ()
  "Show the current playlist in a buffer."
  (interactive)
  (if (null emacs-playlist--playlist)
      (message "Playlist is empty")
    (let ((buf (get-buffer-create emacs-playlist--playlist-buffer-name)))
      (with-current-buffer buf
        (emacs-playlist-mode)
        (setq tabulated-list-entries
              (cl-loop for entry in (reverse emacs-playlist--playlist)
                       for i from 1
                       collect
                       (list (plist-get entry :url)
                             (vector
                              (number-to-string i)
                              (emacs-playlist--format-duration
                               (plist-get entry :duration))
                              (plist-get entry :title)
                              (plist-get entry :channel)))))
        (tabulated-list-print t))
      (pop-to-buffer buf)
      (message "%d songs in playlist — f to finalize, d to remove, s to search more"
               (length emacs-playlist--playlist)))))

(defun emacs-playlist-remove-at-point ()
  "Remove the entry at point from the playlist."
  (interactive)
  (let ((url (tabulated-list-get-id)))
    (when url
      (setq emacs-playlist--playlist
            (cl-remove url emacs-playlist--playlist
                       :key (lambda (e) (plist-get e :url))
                       :test #'string=))
      (emacs-playlist-show-playlist)
      (message "%d songs remaining" (length emacs-playlist--playlist)))))

(defun emacs-playlist-clear ()
  "Clear the entire playlist."
  (interactive)
  (when (yes-or-no-p (format "Clear all %d songs from playlist? "
                             (length emacs-playlist--playlist)))
    (setq emacs-playlist--playlist nil)
    (let ((buf (get-buffer emacs-playlist--playlist-buffer-name)))
      (when buf (kill-buffer buf)))
    (message "Playlist cleared")))

;;;; Download and convert

(defun emacs-playlist-finalize ()
  "Download all playlist entries, convert to 48 kHz, and send to a destination."
  (interactive)
  (when (null emacs-playlist--playlist)
    (user-error "Playlist is empty"))
  (let* ((names (mapcar #'car emacs-playlist-destinations))
         (dest (completing-read
                (format "Send %d songs to: " (length emacs-playlist--playlist))
                names nil t))
         (fn (alist-get dest emacs-playlist-destinations nil nil #'string=))
         (entries (reverse emacs-playlist--playlist))
         (dir emacs-playlist-download-dir))
    (make-directory dir t)
    (let ((state (list :queue (copy-sequence entries)
                       :active 0
                       :total (length entries)
                       :files nil
                       :dir dir
                       :callback fn)))
      (message "emacs-playlist: downloading %d songs..." (length entries))
      (emacs-playlist--drain state))))

(defun emacs-playlist--drain (state)
  "Start downloads from STATE queue up to the concurrency limit."
  (while (and (plist-get state :queue)
              (< (plist-get state :active) emacs-playlist-max-concurrent))
    (let ((entry (pop (plist-get state :queue))))
      (plist-put state :active (1+ (plist-get state :active)))
      (emacs-playlist--start-one entry state))))

(defun emacs-playlist--start-one (entry state)
  "Download ENTRY audio with yt-dlp, convert with ffmpeg, update STATE."
  (let* ((dir (plist-get state :dir))
         (url (plist-get entry :url))
         (title (plist-get entry :title))
         (safe-name (emacs-playlist--sanitize-filename title))
         (tmp-template (expand-file-name "%(id)s.%(ext)s" dir))
         (final-file (expand-file-name (concat safe-name ".wav") dir))
         (buf (generate-new-buffer " *emacs-playlist-dl*"))
         (proc (with-current-buffer buf
                 (setq default-directory dir)
                 (start-process "emacs-playlist-dl" buf
                                "yt-dlp" "-x"
                                "--audio-format" "wav"
                                "-o" tmp-template
                                url))))
    (set-process-query-on-exit-flag proc nil)
    (set-process-sentinel
     proc
     (lambda (p _event)
       (when (memq (process-status p) '(exit signal))
         (let ((dl-file nil))
           ;; Find the downloaded file from yt-dlp output
           (with-current-buffer (process-buffer p)
             (goto-char (point-min))
             (when (re-search-forward
                    "\\[ExtractAudio\\] Destination: \\(.+\\)$" nil t)
               (setq dl-file (expand-file-name (match-string 1) dir)))
             (unless dl-file
               (goto-char (point-min))
               (when (re-search-forward
                      "\\[download\\] \\(.+\\) has already been downloaded" nil t)
                 (setq dl-file (expand-file-name (match-string 1) dir)))))
           (kill-buffer (process-buffer p))
           (if (and dl-file (file-exists-p dl-file))
               ;; Convert with ffmpeg to 48kHz
               (emacs-playlist--convert dl-file final-file state)
             ;; Download failed, skip this entry
             (message "emacs-playlist: failed to download %s" title)
             (emacs-playlist--finish-one state))))))))

(defun emacs-playlist--convert (input-file output-file state)
  "Convert INPUT-FILE to OUTPUT-FILE at 48 kHz, then update STATE."
  (let* ((buf (generate-new-buffer " *emacs-playlist-ffmpeg*"))
         (proc (start-process "emacs-playlist-ffmpeg" buf
                              "ffmpeg" "-y" "-i" input-file
                              "-ar" (number-to-string
                                     emacs-playlist-sample-rate)
                              "-ac" "1"
                              output-file)))
    (set-process-query-on-exit-flag proc nil)
    (set-process-sentinel
     proc
     (lambda (p _event)
       (when (memq (process-status p) '(exit signal))
         (kill-buffer (process-buffer p))
         ;; Clean up the intermediate file
         (when (and (file-exists-p input-file)
                    (not (string= input-file output-file)))
           (delete-file input-file))
         (if (and (zerop (process-exit-status p))
                  (file-exists-p output-file))
             (progn
               (plist-put state :files
                          (cons output-file (plist-get state :files)))
               (message "emacs-playlist: converted %s"
                        (file-name-nondirectory output-file)))
           (message "emacs-playlist: ffmpeg failed for %s" input-file))
         (emacs-playlist--finish-one state))))))

(defun emacs-playlist--finish-one (state)
  "Decrement active count in STATE, drain queue or finalize."
  (plist-put state :active (1- (plist-get state :active)))
  (let ((done (- (plist-get state :total)
                 (plist-get state :active)
                 (length (plist-get state :queue)))))
    (message "emacs-playlist: %d/%d done" done (plist-get state :total)))
  (if (and (null (plist-get state :queue))
           (zerop (plist-get state :active)))
      ;; All done
      (let ((files (nreverse (plist-get state :files)))
            (callback (plist-get state :callback)))
        (if (null files)
            (message "emacs-playlist: no files were downloaded")
          (message "emacs-playlist: all downloads complete (%d files)"
                   (length files))
          (funcall callback files)))
    (emacs-playlist--drain state)))

;;;; Destination helpers

(defun emacs-playlist--send-norns (files)
  "Upload FILES to norns dust/audio/ via sftp in a date-stamped folder."
  (let* ((folder (downcase (format-time-string "%b%d")))
         (remote-dir (format "dust/audio/%s" folder))
         (host emacs-playlist-norns-host)
         (user emacs-playlist-norns-user)
         (buf (generate-new-buffer " *emacs-playlist-norns*"))
         (cmds (concat (format "mkdir %s\n" remote-dir)
                       (mapconcat (lambda (f)
                                    (format "put %s %s/" f remote-dir))
                                  files "\n")
                       "\nbye\n")))
    (with-current-buffer buf (insert cmds))
    (let ((proc (start-process "emacs-playlist-norns" buf
                               "sftp" "-b" "-"
                               (format "%s@%s" user host))))
      (set-process-query-on-exit-flag proc nil)
      (process-send-string proc cmds)
      (process-send-eof proc)
      (set-process-sentinel
       proc
       (lambda (p _event)
         (when (memq (process-status p) '(exit signal))
           (if (zerop (process-exit-status p))
               (message "emacs-playlist: uploaded %d file(s) to norns:%s"
                        (length files) remote-dir)
             (message "emacs-playlist: norns upload failed (exit %d) — see %s"
                      (process-exit-status p)
                      (buffer-name (process-buffer p))))))))))

(defun emacs-playlist--send-vlc (files)
  "Upload FILES to VLC Wi-Fi sharing."
  (let ((url (format "http://%s:%d/upload.json"
                     emacs-playlist-vlc-host
                     emacs-playlist-vlc-port)))
    (dolist (f files)
      (let ((buf (generate-new-buffer
                  (format " *emacs-playlist-vlc: %s*"
                          (file-name-nondirectory f)))))
        (start-process "emacs-playlist-vlc" buf
                       "curl" "-s" "-F"
                       (format "files[]=@%s" f)
                       url)))
    (message "emacs-playlist: uploading %d file(s) to VLC" (length files))))

(defun emacs-playlist--send-open-folder (files)
  "Open the directory containing FILES."
  (when files
    (let ((dir (file-name-directory (car files))))
      (if (fboundp 'browse-url-xdg-open)
          (browse-url-xdg-open dir)
        (browse-url (concat "file://" dir))))))

(provide 'emacs-playlist)
;;; emacs-playlist.el ends here
