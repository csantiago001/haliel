// firebase-messaging-sw.js
importScripts('https://www.gstatic.com/firebasejs/9.23.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/9.23.0/firebase-messaging-compat.js');

// Config de Firebase (MISMA que en index.html)
firebase.initializeApp({
  apiKey: "AIzaSyBnUyK1E8B_EiYUjHw1BxrKsvP2yTZheFs",
  authDomain: "haliel.firebaseapp.com",
  projectId: "haliel",
  storageBucket: "haliel.firebasestorage.app",
  messagingSenderId: "400290356422",
  appId: "1:400290356422:web:6503e67049429f1f018bc7"
});

const messaging = firebase.messaging();

// Manejar notificaciones en segundo plano
messaging.onBackgroundMessage((payload) => {
  const notificationTitle = payload.notification?.title || 'Haliel Papelería';
  const notificationOptions = {
    body: payload.notification?.body || 'Nuevo movimiento registrado',
    icon: payload.notification?.icon || '/logo.png',
    badge: payload.notification?.icon || '/logo.png',
    data: payload.data
  };
  
  self.registration.showNotification(notificationTitle, notificationOptions);
});

// Click en notificación
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow('/'));
});