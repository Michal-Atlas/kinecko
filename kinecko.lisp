#!/usr/bin/env -S sbcl --script

(require :asdf)
(require :dexador)
(require :com.inuoe.jzon)

;; (setf dex:*verbose* t)
(defvar *api-path* (quri:uri "https://api.themoviedb.org/3/movie/"))
(defvar *img-api-path* (quri:uri "https://image.tmdb.org/t/p/original/"))
(defvar *api-key* (uiop:getenv "TMDB_KEY"))
(defvar *db-file* #P"movies.txt")

(defstruct movie
  id title image-url)

(defun movie-path (m)
  (make-pathname :name (format nil "~a" (movie-id m))
                 :type "jpg"
                 :defaults #P"store/"))

(defun movie-poster (m)
  (let ((path (movie-path m)))
    (unless (uiop:file-exists-p path)
      (format t "Downloading poster for '~a'... " (movie-title m))
      (ensure-directories-exist path :verbose t)
      (alexandria.2:write-byte-vector-into-file
       (dex:get (quri:merge-uris
                 (format nil ".~a" (movie-image-url m))
                 *img-api-path*))
       path)
      (format t "done~%"))))

(defun id-movie (id)
  (format t "Downloading movie info for ~a... " id)
  (let* ((table
          (com.inuoe.jzon:parse
           (dex:get
            (quri:merge-uris
             (quri:make-uri
              :path (write-to-string id)
              :query `(("api_key" . ,*api-key*)))
             *api-path*))))
         (movie (make-movie :id id
                            :title (gethash "original_title" table)
                            :image-url (gethash "poster_path" table))))
    (format t "identified as '~a'... done~%" (movie-title movie))
    movie))

(let ((movies
        (uiop:with-input-file (s *db-file*)
          (mapcar (lambda (m)
                    (typecase m
                      (number (id-movie m))
                      (t m)
                      ))
                  (read s)))))
  (uiop:with-output-file (s *db-file* :if-exists :supersede)
    (pprint movies s))
  (dolist (m movies)
    (movie-poster m))
  (format t "Running gmic...~%")
  (uiop:run-program
   (append '("gmic")
           (mapcar (alexandria.2:compose
                    #'namestring
                    #'movie-path)
                   movies)
           '("rr2d"
             "2000,1000"
             "frame"
             ",3,0,0,0"
             "pack"
             "1,-k"
             "output")
           '("output.jpg"))))
