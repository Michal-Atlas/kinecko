(require :asdf)
(require :dexador)
(require :com.inuoe.jzon)

;; (setf dex:*verbose* t)
(defvar *api-path* "https://api.themoviedb.org/3")
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
      (alexandria.2:write-byte-vector-into-file
       (dex:get (format nil "https://image.tmdb.org/t/p/original~a"
                        (movie-image-url m)))
       path)
      (format t "done~%"))))

(defun id-movie (id)
  (format t "Downloading movie info for ~a... " id)
  (let* ((table
          (com.inuoe.jzon:parse
           (dex:get
            (format nil
                    "~a/movie/~a?api_key=~a"
                    *api-path* id *api-key*))))
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
