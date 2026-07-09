#!/usr/bin/env -S sbcl --script

(require :asdf)
(asdf:load-systems
 :dexador
 :com.inuoe.jzon)

;; (setf dex:*verbose* t)
(defvar *api-path* (quri:uri "https://api.themoviedb.org/3/"))
(defvar *img-api-path* (quri:uri "https://image.tmdb.org/t/p/original/"))
(defvar *api-key* (uiop:getenv "TMDB_KEY"))
(defvar *db-file* #P"movies.txt")

(deftype media-type ()
  `(member :movie :series))

(defstruct media
  (id nil :type string)
  (title nil :type string)
  (image-url nil :type string)
  (mtype nil :type media-type))

(defun media-path (m)
  (make-pathname :name (media-id m)
                 :type "jpg"
                 :defaults #P"store/"))

(defun media-poster (m)
  (let ((path (media-path m)))
    (unless (uiop:file-exists-p path)
      (format t "Downloading poster for '~a'... " (media-title m))
      (ensure-directories-exist path :verbose t)
      (alexandria.2:write-byte-vector-into-file
       (dex:get (quri:merge-uris
                 (format nil ".~a" (media-image-url m))
                 *img-api-path*))
       path)
      (format t "done~%"))
    path))

(defun get-media (id)
  (format t "Downloading media info for ~a... " id)
  (let* ((mediatype
           (ecase (aref id 0)
             (#\m :movie)
             (#\s :series)))
         (rawid (subseq id 1))
         (table
           (com.inuoe.jzon:parse
            (dex:get
             (quri:merge-uris
              (quri:make-uri
               :path (format nil "~a/~a"
                             (ecase mediatype
                               (:movie "movie")
                               (:series "tv"))
                             rawid)
               :query `(("api_key" . ,*api-key*)))
              *api-path*))))
         (media (make-media :id rawid
                            :title (gethash
                                    (ecase mediatype
                                      (:movie "original_title")
                                      (:series "original_name"))
                                    table)
                            :mtype mediatype
                            :image-url (gethash "poster_path" table))))
    (format t "identified as '~a'... done~%" (media-title media))
    media))

(let ((movies
        (uiop:with-input-file (s *db-file*)
          (mapcar (lambda (m)
                    (typecase m
                      (string (get-media m))
                      (t m)
                      ))
                  (read s)))))
  (uiop:with-output-file (s *db-file* :if-exists :supersede)
    (pprint movies s))
  (dolist (m movies)
    (media-poster m))
  (format t "Running gmic...~%")
  (uiop:run-program
   (append '("gmic")
           (mapcar (alexandria.2:compose
                    #'namestring
                    #'media-path)
                   movies)
           '("rr2d"
             "2000,1000"
             "frame"
             ",3,0,0,0"
             "pack"
             "1,-k"
             "output")
           '("output.jpg"))))
