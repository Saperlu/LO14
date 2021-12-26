#! /bin/bash

# Ce script implémente un serveur.
# Le script doit être invoqué avec l'argument :
# PORT   le port sur lequel le serveur attend ses clients

if [ $# -ne 1 ]; then
    echo "usage: $(basename $0) PORT"
    exit -1
fi

PORT="$1"

# Déclaration du tube

FIFO="/tmp/$USER-fifo-$$-serveur"
logger="/tmp/$USER-f-$$-serveur"


# Il faut détruire le tube quand le serveur termine pour éviter de
# polluer /tmp.  On utilise pour cela une instruction trap pour être sur de
# nettoyer même si le serveur est interrompu par un signal.

function nettoyage() { rm -f "$FIFO" "$logger"; }
trap nettoyage EXIT

# on crée le tube nommé

[ -e "$FIFO" ] || mkfifo "$FIFO"
[ -e "$logger" ] || mkfifo "$logger"


function accept-loop() {
    while true; do
    interaction < "$FIFO" | netcat -l -p "$PORT" > "$FIFO" 2>/dev/null
    cat "$logger" | cut -c1-60
    done
}

# La fonction interaction lit les commandes du client sur entrée standard
# et envoie les réponses sur sa sortie standard.
#
# 	CMD arg1 arg2 ... argn
#
# alors elle invoque la fonction :
#
#         commande-CMD arg1 arg2 ... argn
#
# si elle existe; sinon elle envoie une réponse d'erreur.

function interaction() {
    local cmd args
    while true; do
        read -r cmd args || exit -1
        echo "$cmd $args" > "$logger" &
        fun="commande-$cmd"
        if [ "$(type -t $fun)" = "function" ]; then
            $fun $args
        else
            commande-non-comprise $fun $args
        fi
    done
}

# Les fonctions implémentant les différentes commandes du serveur


function commande-non-comprise () {
    echo "Le serveur ne peut pas interpréter cette commande"
}

function commande-echo () {
    if [ $1 == "bonjour" ]
    then
        echo "bonjour, je suis à votre service"
    fi
}

function commande-list () {
    # Le nombre d'archives suivi des noms des archives
    # Récupérer les noms différentes archives
    i=0
    while read line
    do
      while find -name "tar"
      do
        array [ $i ]="$line"
        ((i++))
      done < <(ls -ls)
    done
    # Afficher le nombre d'archives et le tableau avec le nom des archives
    j=0
    echo "Il y a $i archives."
    while !j=i
    do
      echo "Archive $i : "
      echo "${array[i]}"
      ((i++))
    done
    #echo "4
    #        archive 1
    #        archive 2
    #        archive 3
    #        archive 4"
}
function commande-create () {
    nom=$1
    archive=$2
    dossier="/tmp/dossier-$USER-$$-$nom"
    mkdir "$dossier"
    echo $archive | base64 -d | tar -xz -C "$dossier"
    # Tout se trouve dans le dossier $dossier


    #Deux fichiers qu'on va concaténer à la fin
    touch header.txt
    touch body.txt

    #On laisse une ligne en haut pour noter le début du header et du body
    echo -e "\n" >> header.txt
    curseur_body=0
    find "$dossier" -type d | while read absolute
    do
        relative=$(printf "%s" $absolute | sed s:^$dossier::)
        echo "directory $relative" >> header.txt

        ls -l "$absolute" | sed /^total/d | while read rights _ _ _ size _ _ _ name
        do
            export toprint="$name $rights"
            if [[ "$size" != "0" ]]
            then
                export toprint="$toprint $size"
                if [[ -f "$absolute/$name" ]]
                then
                    export toprint="$toprint $((($(wc -l body.txt | egrep -o '[0-9]+' | head -n 1)+1))) $(wc -l $absolute/$name | egrep -o '[0-9]+' | head -n 1)"
                    cat "$absolute/$name" >> body.txt
                fi
            fi
            echo $toprint
        done >> header.txt
        echo "@" >> header.txt
    done

    #On cherche les directory
    # for i in $(ls)
    # do
    #   if [ -d $i ]; then
    #     ((d++))
    #     #Mettre le nom du dossier dans le fichiers
    #     echo -e "directory $(ls)\n" >> header.txt
    #     nb_lignes=$(wc -l $(ls))
    #     #Ecrire ce qu'il y a dans le fichier dans l'archive
    #     #cat body.txt ($(ls)).txt > body.txt
    #     taille=$(ls -l $i | cut -d' ' -f5)
    #     echo -e "\n\n" >> body.txt
    #     #Mettre les dossiers et fichiers en-dessous avec nom, droit, poids et début et fin
    #     echo -e "$(ls -a) $(ls -l) $taille $curseur_body (($curseur_body+$nb_lignes))" >> header.txt
    #     (($nb_lignes+=1))
    #     (($curseur_body+=$nb_lignes))
    #   fi
    #   #Mettre un @ pour dire qu'on change de dossier
    #   echo -e "@\n" >> header.txt
    # done

    taille_header=$(wc -l header.txt | egrep -o "[0-9]+")
    #Ajouter au début du fichier header
    # sed -i 1s/.*/`((taille_header+2))`\n/g "header.txt"
    echo "3:$(((taille_header+2)))" | cat - header.txt > temp 
    mv temp header.txt

    #Concaténer header et body
    cat header.txt body.txt > $nom.txt
    rm body.txt
    rm header.txt


    rm -rf "$dossier"
    echo "1
            L'archive $nom a bien été créée"
}

function commande-browse () {
    if [ "$(type -t $fun-$1)" = "function" ]; then
        $fun-$1 $args
    else
        commande-non-comprise $fun $args
    fi
}

function commande-browse-ls () {
    echo "2
            fichier -rwxrw-rw-
            dossier drwxrwxrw-"
}

function commande-browse-cd () {
    archive=$2
    currentDir=$3
    dossier=$4
    # ici, il faut renvoyer le chemin absolu du nouveau répertoire de travail avec des / comme séparateur de dossier
    # chemin absolu = chemin relatif à la racine de l'archive
    echo "1
            /$RANDOM"
}
function commande-browse-cat () {
    archive=$2
    currentDir=$3
    fichier=$4
    echo "1
            contenu du fichier"
}
function commande-browse-rm () {
    archive=$2
    currentDir=$3
    fichier=$4
    echo "1
            $2> $3 $4"
}
function commande-browse-touch () {
    archive=$2
    currentDir=$3
    fichier=$4
    echo "1
            $2> $3 $4"
}
function commande-browse-mkdir () {
    archive=$2
    currentDir=$3
    dossier=$4
    echo "1
            $2> $3 $4"
}


# On accepte et traite les connexions

accept-loop
